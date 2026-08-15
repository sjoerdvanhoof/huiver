import Foundation
import Testing

@testable import HuiverKit

/// The engine, end to end, against the real models.
///
/// Skipped unless `scripts/install-models.sh` has been run, because the models
/// are ~700 MB and are not in the repo. When they are there this is the only
/// test that proves the whole chain works — tokenizer, prefill, the KV-cache
/// copy into Core ML state, the sampling loop, the mel decoder and the vocoder —
/// and it runs on the Mac, so it catches a broken export without a device.
struct EngineTests {
    /// Where the compiled models and voices are installed.
    ///
    /// The iOS app's folder rather than this package's: `install-models.sh`
    /// puts them where the Xcode project references them from, and they are far
    /// too large to keep a second copy of. HuiverKit lives in `packages/` and
    /// the models do not move with it.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HuiverKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // huiverkit
            .deletingLastPathComponent()  // packages
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("apps/ios")
    }

    static var installed: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Models/T3Decode.mlmodelc").path
        )
    }

    /// Generous, because the first run on a given machine is not measuring the
    /// model: Core ML compiles each one for the hardware before it can predict,
    /// which took about twelve minutes here against a few seconds afterwards.
    /// The same wait happens on first launch on the phone.
    @Test("reads a sentence aloud", .timeLimit(.minutes(30)))
    func speaks() async throws {
        try #require(Self.installed, "Models/ not installed; run scripts/install-models.sh")

        let voices = try VoicePack.load(from: Self.root.appendingPathComponent("Voices"))
        #expect(!voices.isEmpty)
        let voice = try #require(voices.first { $0.id == "nano_default" } ?? voices.first)

        // Shapes are fixed by the export, and a voice file that disagrees would
        // fail deep inside Core ML with an unhelpful message.
        #expect(voice.speakerEmbedding.count == 256)
        #expect(voice.condPromptTokens.count == 375)
        #expect(voice.promptTokens.count == 250)
        #expect(voice.promptFeatures.count == 500 * 80)
        #expect(voice.xvector.count == 192)

        // Progress has to be monotonic and stay in range, or the bar on the
        // preparing screen jumps about.
        let seen = Tracker()
        let engine = try await ChatterboxEngine.load(
            models: .init(directory: Self.root.appendingPathComponent("Models"))
        ) { progress in seen.record(progress) }
        #expect(seen.count > 4, "only \(seen.count) progress reports")
        #expect(seen.wentBackwards == false)
        #expect(seen.last == 1.0)

        var options = SamplingOptions()
        options.maxTokens = 400
        let samples = try await engine.speak(
            "The quiet harbour town woke slowly.", voice: voice, options: options
        )

        // About two seconds of speech for that sentence. The bounds are wide on
        // purpose: this is checking that audio came out at a plausible length,
        // not that sampling produced any particular reading.
        let seconds = Double(samples.count) / Double(engine.sampleRate)
        #expect(seconds > 1.0, "only \(seconds)s of audio")
        #expect(seconds < 12.0, "\(seconds)s of audio for one short sentence")

        // Silence would mean the vocoder ran but produced nothing, which is the
        // failure mode a length check alone would miss.
        let peak = samples.map(abs).max() ?? 0
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
        #expect(peak > 0.01, "peak amplitude \(peak)")
        #expect(rms > 0.001, "rms \(rms)")
        #expect(peak <= 1.0)

        // Written out so it can actually be listened to when something sounds
        // wrong; a passing test here still says nothing about how it sounds.
        let out = URL.temporaryDirectory.appendingPathComponent("huiver-engine-test.wav")
        try WavFile.data(from: samples).write(to: out)
        print("wrote \(out.path) — \(String(format: "%.2f", seconds))s, rms \(rms)")
    }

    /// Collects load progress from whatever thread Core ML calls back on.
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double] = []

        func record(_ progress: ChatterboxEngine.LoadProgress) {
            lock.withLock { fractions.append(progress.fraction) }
        }

        var count: Int { lock.withLock { fractions.count } }
        var last: Double? { lock.withLock { fractions.last } }
        var wentBackwards: Bool {
            lock.withLock { zip(fractions, fractions.dropFirst()).contains { $1 < $0 - 1e-9 } }
        }
    }
}
