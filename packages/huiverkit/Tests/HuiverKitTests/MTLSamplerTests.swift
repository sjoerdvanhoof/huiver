import Foundation
import Testing

@testable import HuiverKit

/// The multilingual filter chain, against the Python original.
///
/// `SamplerTests` does this for Nano. The reason it is worth doing twice is the
/// order: the same four filters applied in Nano's sequence give a different
/// distribution, and nothing downstream would report it — the audio would
/// simply be read by a slightly different narrator than the weights were tuned
/// for.
struct MTLSamplerTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            struct Options: Decodable {
                let temperature: Float
                let minP: Float
                let topP: Float
                let repetitionPenalty: Float
            }
            let logits: [Float]
            let history: [Int32]
            /// `null` where the original filtered the token out.
            let filtered: [Float?]
            let options: Options
        }
        let cases: [Case]
    }

    func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "mtl-sampler", withExtension: "json", subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: "mtl-sampler", withExtension: "json")
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    @Test("filtering matches the multilingual original exactly")
    func matchesPython() throws {
        for (index, item) in try fixture().cases.enumerated() {
            var options = SamplingOptions.multilingual
            options.temperature = item.options.temperature
            options.minP = item.options.minP
            options.topP = item.options.topP
            options.repetitionPenalty = item.options.repetitionPenalty

            var sampler = Sampler(options: options, order: .multilingual)
            var logits = item.logits
            logits.withUnsafeMutableBufferPointer { buffer in
                sampler.filter(logits: buffer, history: Set(item.history))
            }

            var mismatches = 0
            for (token, want) in item.filtered.enumerated() {
                let got = logits[token]
                if let want {
                    // float32 through a different order of the same arithmetic:
                    // equal to within rounding, not bit-identical.
                    if !got.isFinite || abs(got - want) > max(1e-4, abs(want) * 1e-5) {
                        mismatches += 1
                    }
                } else if got.isFinite {
                    mismatches += 1
                }
            }
            #expect(mismatches == 0, "case \(index): \(mismatches) tokens differ")
        }
    }

    /// What the order actually buys, tested rather than asserted.
    ///
    /// Temperature and the penalty commute — both are multiplications — so the
    /// difference between the two orders is not in the scaling. It is that the
    /// multilingual chain penalises *before* it cuts, so a penalised peak
    /// lowers the min-p floor and lets more of the tail through; Nano's cuts
    /// first, where the penalty can no longer change who survives.
    @Test("penalising before the cut changes who survives it")
    func penaltyBeforeCut() {
        var options = SamplingOptions.multilingual
        options.temperature = 1
        options.topP = 1
        options.minP = 0.5
        options.repetitionPenalty = 4

        func survivors(history: Set<Int32>) -> Int {
            var sampler = Sampler(options: options, order: .multilingual)
            // A clear peak, then a shoulder that a 0.5 floor would normally cut.
            var logits: [Float] = [4, 3, 2.5, 2]
            logits.withUnsafeMutableBufferPointer {
                sampler.filter(logits: $0, history: history)
            }
            return logits.count { $0.isFinite }
        }

        let untouched = survivors(history: [])
        let peakPenalised = survivors(history: [0])
        #expect(untouched == 1, "only the peak clears a 0.5 floor when nothing is penalised")
        #expect(
            peakPenalised > untouched,
            "penalising the peak first lowers the floor, which is the whole point of the order"
        )
    }

    /// A token cut by min-p must stay cut: the penalty has already run by then,
    /// and multiplying an infinity would bring it back.
    @Test("the penalty never resurrects a filtered token")
    func noResurrection() {
        var options = SamplingOptions.multilingual
        options.minP = 0.5
        options.repetitionPenalty = 1.2
        var sampler = Sampler(options: options, order: .multilingual)
        var logits: [Float] = [4, -20, -30]
        logits.withUnsafeMutableBufferPointer {
            sampler.filter(logits: $0, history: [1, 2])
        }
        #expect(!logits[1].isFinite)
        #expect(!logits[2].isFinite)
    }

    @Test("min-p keeps the peak and drops what is far below it")
    func minP() {
        var options = SamplingOptions.multilingual
        options.temperature = 1
        options.topP = 1
        options.repetitionPenalty = 1
        options.minP = 0.5
        var sampler = Sampler(options: options, order: .multilingual)

        // exp(0) = 1, exp(-0.5) ≈ 0.61, exp(-2) ≈ 0.14 relative to the peak.
        var logits: [Float] = [0, -0.5, -2, -10]
        logits.withUnsafeMutableBufferPointer { sampler.filter(logits: $0, history: []) }
        #expect(logits[0].isFinite)
        #expect(logits[1].isFinite, "0.61 of the peak is above a 0.5 floor")
        #expect(!logits[2].isFinite)
        #expect(!logits[3].isFinite)
    }
}
