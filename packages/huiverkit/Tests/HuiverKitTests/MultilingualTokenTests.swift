import Foundation
import Testing

@testable import HuiverKit

/// The Swift decode loop against torch's, token for token, in two languages.
///
/// `verify_mtl.py` checks the converted models against torch, and
/// `MTLTokenizerTests` checks the text going in — both on English. This checks
/// the part in between, in Swift, on Dutch as well: the assembled prompt, the
/// guidance folded into the first token, the KV cache copied into Core ML
/// state, the learned speech positions, and the stop condition.
///
/// Greedy on both sides, so there is one right answer. The Swift engine has no
/// greedy mode — it samples, as it should — so it is *driven* greedily: a
/// temperature of 0.01 makes the peak's probability indistinguishable from one,
/// and the penalty and both filters are switched off so nothing reorders the
/// logits. Near-greedy rather than greedy, which is why a prefix is compared
/// rather than the whole run.
struct MultilingualTokenTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let text: String
            let language: String
            let tokens: [Int32]
            /// How far apart the top two candidates were at each step, from
            /// torch. A small gap means the two implementations are choosing
            /// between tokens they both consider equally likely.
            let gaps: [Double]
        }
        let steps: Int
        /// The gap above which a choice is decisive, from the generator.
        let decisive: Double
        let cases: [Case]
    }

    /// How many tokens to walk before giving up on comparing.
    ///
    /// Twelve is plenty: a wrong prompt, a mis-seeded cache or a learned
    /// position off by one does not agree for two.
    static let walked = 12

    func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "mtl-tokens", withExtension: "json", subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: "mtl-tokens", withExtension: "json")
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    @Test("the same text gives the same speech tokens as torch", .timeLimit(.minutes(60)))
    func matchesTorch() async throws {
        try #require(
            MultilingualEngineTests.installed,
            "apps/mac/Models has no multilingual models; run bun run mac:models && mac:install"
        )
        let root = MultilingualEngineTests.root
        let voices = try VoicePack.load(from: root.appendingPathComponent("Voices"))
        // The fixture was generated with the checkpoint's own built-in voice.
        let voice = try #require(voices.first { $0.id == "mtl_default" })
        let engine = try await ChatterboxEngine.load(
            models: .init(directory: root.appendingPathComponent("Models"))
        )

        var options = SamplingOptions.multilingual
        options.temperature = 0.01
        options.repetitionPenalty = 1
        options.minP = 0
        options.topP = 1
        options.maxTokens = Self.walked

        let fixture = try fixture()
        var deepest = 0
        for item in fixture.cases {
            let got = try await engine.generateSpeechTokens(
                for: item.text,
                voice: voice,
                options: options,
                language: .named(item.language),
                cancelled: { false }
            )

            // Walk until the two disagree. A disagreement is a fault only where
            // torch itself had a clear preference; where the top two candidates
            // were a hundredth apart, float16 weights and int8 quantisation make
            // the choice a coin toss and the sequences legitimately part company
            // — after which every later token is conditioned on a different
            // history and comparing them would be comparing nothing.
            var matched = 0
            for step in 0..<min(Self.walked, min(got.count, item.tokens.count)) {
                if got[step] == item.tokens[step] {
                    matched += 1
                    continue
                }
                let gap = step < item.gaps.count ? item.gaps[step] : 0
                #expect(
                    gap <= fixture.decisive,
                    """
                    \(item.language) "\(item.text)" diverged at step \(step) where torch was                     sure (gap \(gap)): got \(got[step]), torch chose \(item.tokens[step])
                      swift \(Array(got.prefix(Self.walked)))
                      torch \(Array(item.tokens.prefix(Self.walked)))
                    """
                )
                break
            }
            deepest = max(deepest, matched)
            print(
                "\(item.language): matched \(matched) of \(Self.walked) tokens "
                    + "(\(item.gaps.prefix(matched + 1).filter { $0 > fixture.decisive }.count) decisive)"
            )
        }

        // One case agreeing for a single token would satisfy every expectation
        // above while proving nothing, so the depth is asserted too.
        #expect(deepest >= 6, "no case matched more than \(deepest) tokens")
    }
}
