import Foundation
import Testing

@testable import HuiverKit

/// Cloning a voice on the phone's models, against the real package.
///
/// `VoiceClonerTests` is the same chain for the Mac's multilingual cloner. This
/// one matters separately because almost everything about Nano's clone differs:
/// a fifteen-second window rather than ten, a 375-token conditioning prompt
/// rather than 150, and a clip normalised to −27 LUFS first. Each of those was
/// wrong in the first export and each produced a voice rather than an error, so
/// the shapes below are the assertions worth having.
///
/// Skipped unless `bun run ios:install` has put a Nano export with a cloner in
/// `apps/ios/Models`.
struct NanoVoiceClonerTests {
    static var models: URL { EngineTests.root.appendingPathComponent("Models") }
    static var available: Bool {
        EngineTests.installed && VoiceCloner.isAvailable(in: models)
    }

    /// A real recording, long enough to fill the window without padding.
    ///
    /// The reference clips in the repo are thirteen seconds and the window is
    /// fifteen, so the clip is played twice — the same speaker either way, and
    /// what is under test is the pipeline rather than the prose. A padded clip
    /// would still clone; it would just be the case the sheet warns about.
    static func recording() throws -> [Float] {
        let url = EngineTests.root
            .deletingLastPathComponent()  // apps
            .appendingPathComponent("../tools/voices/clips/nl.wav")
            .standardizedFileURL
        let once = WavFile.samples(from: try Data(contentsOf: url))
        return once + once
    }

    @Test("clones a recording into a voice Nano can read", .timeLimit(.minutes(30)))
    func clones() async throws {
        try #require(Self.available, "no VoiceCloner in apps/ios/Models")

        let cloner = try await VoiceCloner(models: Self.models)
        // The package says what it wants and the app believes it. Fifteen
        // seconds and −27 LUFS are Nano's; a cloner that reported the
        // multilingual ten would clone from the wrong window and say nothing.
        #expect(cloner.clipSeconds == 15)
        #expect(cloner.targetLufs == -27)

        let voice = try await cloner.clone(
            try Self.recording(), id: "test_nano_clone", name: "Test",
            detail: "a cloned recording", language: "en"
        )

        // The shapes `ChatterboxEngine.validate` checks a voice against.
        #expect(voice.speakerEmbedding.count == 256)
        #expect(voice.condPromptTokens.count == 375)
        #expect(voice.promptTokens.count == 250)
        #expect(voice.promptFeatures.count == 500 * 80)
        #expect(voice.xvector.count == 192)

        // A conditioning prompt of 375 zeros would pass the count above. The
        // first export produced 150 real tokens and 225 of them, which is what
        // this is here to catch.
        #expect(Set(voice.condPromptTokens.suffix(200)).count > 10, "the tail is not real speech")
        #expect(Set(voice.promptTokens).count > 20, "tokens should vary")
        #expect(
            abs(voice.speakerEmbedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.01,
            "the speaker embedding is L2-normalised"
        )

        // Round trip through the file format `export_voices.py` also writes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-nano-clone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try VoicePack.write(voice, to: directory)
        let reloaded = try #require(try VoicePack.load(from: directory).first)
        #expect(reloaded.condPromptTokens == voice.condPromptTokens)
        #expect(reloaded.promptFeatures == voice.promptFeatures)
    }

    /// The whole point, end to end: a recording goes in and the engine reads a
    /// sentence out in that voice. `canRead` is checked explicitly because the
    /// app filters its roster with it — a voice that fails there is invisible
    /// rather than broken, which is a harder thing to notice.
    @Test("a cloned voice reads a sentence", .timeLimit(.minutes(60)))
    func speaks() async throws {
        try #require(Self.available, "no VoiceCloner in apps/ios/Models")

        let cloner = try await VoiceCloner(models: Self.models)
        let voice = try await cloner.clone(
            try Self.recording(), id: "test_nano_clone", name: "Test",
            detail: "cloned", language: "en"
        )

        let engine = try await ChatterboxEngine.load(models: .init(directory: Self.models))
        #expect(await engine.canRead(voice))

        var options = SamplingOptions()
        options.maxTokens = 400
        let samples = try await engine.speak(
            "The quiet harbour town woke slowly.", voice: voice, options: options
        )

        let seconds = Double(samples.count) / Double(engine.sampleRate)
        let peak = samples.map(abs).max() ?? 0
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
        #expect(seconds > 1, "only \(seconds)s")
        #expect(peak > 0.01, "peak \(peak)")
        #expect(rms > 0.001, "rms \(rms)")

        // Written out because a passing test still says nothing about whether
        // it sounds like the person who read the clip.
        let out = URL.temporaryDirectory.appendingPathComponent("huiver-nano-cloned.wav")
        try WavFile.data(from: samples).write(to: out)
        print("cloned nano voice: \(out.path) — \(String(format: "%.2f", seconds))s, rms \(rms)")
    }
}
