import Foundation
import Testing

@testable import HuiverKit

/// The multilingual engine, end to end, against the real models.
///
/// The twin of `EngineTests`, and the acceptance test for the Mac: it proves
/// the whole multilingual chain — the grapheme tokenizer, the guided prefill,
/// the two-row KV cache copied into Core ML state, the sampler in *its* order,
/// the ten-step solver and the vocoder — produces audio, and that it produces
/// audio in a language Nano could not read.
///
/// Skipped unless `bun run mac:install` has put multilingual models in
/// `apps/mac/Models`. They are 2.4 GB and are not in the repo.
struct MultilingualEngineTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HuiverKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // huiverkit
            .deletingLastPathComponent()  // packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("apps/mac")
    }

    static var installed: Bool {
        // The MLX backbone is the multilingual install now; the Core ML T3
        // pair it replaced is no longer shipped.
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Models/MTLT3Backbone.safetensors").path
        )
    }

    /// Longer than Nano's: nine times the arithmetic per token, twenty
    /// estimator passes per window, and a first run that compiles 2.4 GB of
    /// models for this machine before it can predict anything.
    @Test("reads a sentence aloud in English and in Dutch", .timeLimit(.minutes(60)))
    func speaks() async throws {
        try #require(
            Self.installed,
            "apps/mac/Models has no multilingual models; run bun run mac:models && bun run mac:install"
        )

        let voices = try VoicePack.load(from: Self.root.appendingPathComponent("Voices"))
        let voice = try #require(voices.first { $0.id == "mtl_default" } ?? voices.first)

        // The shapes that differ from Nano's, checked here because a voice
        // cloned through the wrong checkpoint fails deep inside Core ML.
        #expect(voice.speakerEmbedding.count == 256)
        #expect(
            voice.condPromptTokens.count == 150,
            "the multilingual conditioning prompt is 150 tokens, not Nano's 375"
        )
        #expect(voice.promptTokens.count == 250)
        #expect(voice.promptFeatures.count == 500 * 80)
        #expect(voice.xvector.count == 192)

        let engine = try await ChatterboxEngine.load(
            models: .init(directory: Self.root.appendingPathComponent("Models"))
        )
        #expect(engine.variant == .multilingual, "the MTL* models should select the MTL path")

        // 23 languages minus the five whose text needs a normaliser this app
        // does not have.
        let languages = engine.languages.map(\.code)
        #expect(languages.contains("nl"))
        #expect(languages.contains("en"))
        #expect(!languages.contains("zh"), "Chinese needs Cangjie decomposition")
        #expect(!languages.contains("ru"), "Russian needs stress marking")

        var options = SamplingOptions.multilingual
        options.maxTokens = 400

        // Two short ones and a long one. The long Dutch sentence is the case
        // worth having: a two-second clip is too little for any recogniser to
        // place a language from, so it is the only one whose output can be
        // checked against upstream's by ear or by transcription.
        let cases: [(text: String, language: Language)] = [
            ("The quiet harbour town woke slowly.", .english),
            ("Het stadje aan de haven werd langzaam wakker.", .named("nl")),
            (
                "De schrijver liep langzaam door de oude stad en dacht aan zijn jeugd.",
                .named("nl")
            ),
        ]
        for (index, (text, language)) in cases.enumerated() {
            let samples = try await engine.speak(
                text, voice: voice, options: options, language: language
            )
            let seconds = Double(samples.count) / Double(engine.sampleRate)
            let peak = samples.map(abs).max() ?? 0
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
                .squareRoot()

            #expect(seconds > 1.0, "\(language.code): only \(seconds)s of audio")
            #expect(seconds < 20.0, "\(language.code): \(seconds)s for one sentence")
            #expect(peak > 0.01, "\(language.code): peak \(peak)")
            #expect(peak <= 1.0)
            #expect(rms > 0.001, "\(language.code): rms \(rms)")

            // Written out so it can be listened to: a passing test says audio
            // came out, not that it is in the right language.
            let out = URL.temporaryDirectory
                .appendingPathComponent("huiver-mtl-\(index)-\(language.code).wav")
            try WavFile.data(from: samples).write(to: out)
            print(
                "\(language.code): \(out.path) — \(String(format: "%.2f", seconds))s, rms \(rms)"
            )
        }
    }

    /// A language the tokenizer cannot prepare must be refused before any
    /// audio is rendered, not read with the wrong pronunciation.
    @Test("a language needing an unported normaliser is refused", .timeLimit(.minutes(60)))
    func refusesUnsupported() async throws {
        try #require(Self.installed, "multilingual models not installed")
        let voices = try VoicePack.load(from: Self.root.appendingPathComponent("Voices"))
        let voice = try #require(voices.first)
        let engine = try await ChatterboxEngine.load(
            models: .init(directory: Self.root.appendingPathComponent("Models"))
        )
        await #expect(throws: ChatterboxEngine.EngineError.self) {
            _ = try await engine.speak("你好", voice: voice, language: Language.named("zh"))
        }
    }
}
