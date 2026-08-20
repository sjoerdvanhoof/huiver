import Foundation
import Testing

@testable import HuiverKit

/// Cloning a voice in the app, against the real model.
///
/// Skipped unless `bun run mac:install` has put a multilingual export in
/// `apps/mac/Models`. What it proves is the whole chain the Python tooling used
/// to own: a recording in, five tensors out, a `.voice` file written, read back,
/// and speech rendered in that voice.
struct VoiceClonerTests {
    static var models: URL { MultilingualEngineTests.root.appendingPathComponent("Models") }

    static var available: Bool { VoiceCloner.isAvailable(in: models) }

    /// A real recording rather than a tone: the reference clips the language
    /// voices were cloned from are 24 kHz mono WAVs, which is the shape a
    /// recording arrives in.
    static func clip(_ language: String = "nl") throws -> [Float] {
        let url = MultilingualEngineTests.root
            .deletingLastPathComponent()  // apps
            .appendingPathComponent("../tools/voices/clips/\(language).wav")
            .standardizedFileURL
        return WavFile.samples(from: try Data(contentsOf: url))
    }

    @Test("clones a recording into a usable voice", .timeLimit(.minutes(30)))
    func clones() async throws {
        try #require(Self.available, "no MTLVoiceCloner in apps/mac/Models")
        let recording = try Self.clip()
        #expect(recording.count > 10 * 24000, "the fixture clip should be over ten seconds")

        let cloner = try await VoiceCloner(models: Self.models)
        let voice = try await cloner.clone(
            recording, id: "test_clone", name: "Test", detail: "a cloned recording",
            language: "nl"
        )

        // The shapes the engine validates against the loaded models.
        #expect(voice.speakerEmbedding.count == 256)
        #expect(voice.condPromptTokens.count == 150)
        #expect(voice.promptTokens.count == 250)
        #expect(voice.promptFeatures.count == 500 * 80)
        #expect(voice.xvector.count == 192)

        // Tensors that are all one value would pass every shape check and
        // produce silence.
        #expect(voice.speakerEmbedding.contains { $0 != 0 })
        #expect(Set(voice.promptTokens).count > 20, "tokens should vary")
        #expect(
            abs(voice.speakerEmbedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.01,
            "the speaker embedding is L2-normalised"
        )

        // Written, read back, identical — the format is shared with
        // export_voices.py, so a round trip here is a round trip there.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try VoicePack.write(voice, to: directory)

        let reloaded = try #require(try VoicePack.load(from: directory).first)
        #expect(reloaded.id == voice.id)
        #expect(reloaded.language == "nl")
        #expect(reloaded.speakerEmbedding == voice.speakerEmbedding)
        #expect(reloaded.condPromptTokens == voice.condPromptTokens)
        #expect(reloaded.promptTokens == voice.promptTokens)
        #expect(reloaded.promptFeatures == voice.promptFeatures)
        #expect(reloaded.xvector == voice.xvector)
    }

    @Test("a cloned voice can read a sentence", .timeLimit(.minutes(60)))
    func speaks() async throws {
        try #require(Self.available, "no MTLVoiceCloner in apps/mac/Models")
        let cloner = try await VoiceCloner(models: Self.models)
        let voice = try await cloner.clone(
            try Self.clip(), id: "test_clone", name: "Test", detail: "cloned", language: "nl"
        )

        let engine = try await ChatterboxEngine.load(models: .init(directory: Self.models))
        var options = SamplingOptions.multilingual
        options.maxTokens = 400
        let samples = try await engine.speak(
            "Het stadje aan de haven werd langzaam wakker.",
            voice: voice, options: options, language: .named("nl")
        )

        let seconds = Double(samples.count) / Double(engine.sampleRate)
        let peak = samples.map(abs).max() ?? 0
        #expect(seconds > 1, "only \(seconds)s")
        #expect(peak > 0.01, "peak \(peak)")

        let out = URL.temporaryDirectory.appendingPathComponent("huiver-cloned-voice.wav")
        try WavFile.data(from: samples).write(to: out)
        print("cloned voice: \(out.path) — \(String(format: "%.2f", seconds))s")
    }

    /// The same sentence, the same engine, the same reference recording — read
    /// once by the voice this app cloned and once by the voice the Python
    /// tooling cloned from the identical clip.
    ///
    /// Written out rather than asserted on: "does a clone sound like the
    /// speaker" is a question for a speaker-embedding comparison outside this
    /// suite (tools/export has the encoder), and the point of the test is to
    /// produce the two files it needs from a path the app really uses.
    @Test("renders a comparison against the shipped clone", .timeLimit(.minutes(60)))
    func comparison() async throws {
        try #require(Self.available, "no MTLVoiceCloner in apps/mac/Models")
        let voices = try VoicePack.load(
            from: MultilingualEngineTests.root.appendingPathComponent("Voices")
        )
        let shipped = try #require(voices.first { $0.id == "lang_nl" }, "no lang_nl voice")

        let cloner = try await VoiceCloner(models: Self.models)
        let mine = try await cloner.clone(
            try Self.clip(), id: "in_app", name: "In-app", detail: "cloned in the app",
            language: "nl"
        )

        let engine = try await ChatterboxEngine.load(models: .init(directory: Self.models))
        var options = SamplingOptions.multilingual
        options.maxTokens = 500
        let text = "Het stadje aan de haven werd langzaam wakker en de klok sloeg zeven."

        for voice in [shipped, mine] {
            let samples = try await engine.speak(
                text, voice: voice, options: options, language: .named("nl")
            )
            let out = URL.temporaryDirectory
                .appendingPathComponent("huiver-compare-\(voice.id).wav")
            try WavFile.data(from: samples).write(to: out)
            print("\(voice.id): \(out.path)")
            #expect(samples.map(abs).max() ?? 0 > 0.01)
        }
    }

    @Test("silence is refused rather than cloned")
    func refusesSilence() async throws {
        try #require(Self.available, "no MTLVoiceCloner in apps/mac/Models")
        let cloner = try await VoiceCloner(models: Self.models)
        await #expect(throws: VoiceCloner.CloneError.self) {
            _ = try await cloner.clone(
                [Float](repeating: 0, count: 12 * 24000), id: "x", name: "x", detail: "x"
            )
        }
    }

    @Test("a second of speech is refused with a reason")
    func refusesTooShort() async throws {
        try #require(Self.available, "no MTLVoiceCloner in apps/mac/Models")
        let cloner = try await VoiceCloner(models: Self.models)
        let short = (0..<24000).map { index in
            Float(sin(2 * .pi * 180 * Double(index) / 24000) * 0.3)
        }
        await #expect(throws: VoiceCloner.CloneError.self) {
            _ = try await cloner.clone(short, id: "x", name: "x", detail: "x")
        }
    }
}
