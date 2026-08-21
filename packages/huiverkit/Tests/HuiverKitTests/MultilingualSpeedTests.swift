import Foundation
import Testing

@testable import HuiverKit

/// How fast the multilingual model actually is on this machine.
///
/// Not a pass/fail test of anything but sanity — it prints a real-time factor,
/// which is the number that decides whether a chapter can be listened to while
/// it renders or has to be converted first. Nano manages roughly real time on a
/// phone; this model does nine times the arithmetic per token and computes every
/// token twice for guidance, so the answer matters for what the Mac's UI should
/// promise.
struct MultilingualSpeedTests {
    @Test("measures the real-time factor", .timeLimit(.minutes(60)))
    func speed() async throws {
        try #require(MultilingualEngineTests.installed, "multilingual models not installed")
        let root = MultilingualEngineTests.root
        let voices = try VoicePack.load(from: root.appendingPathComponent("Voices"))
        let voice = try #require(voices.first { $0.id == "mtl_default" } ?? voices.first)
        let engine = try await ChatterboxEngine.load(
            models: .init(directory: root.appendingPathComponent("Models"))
        )

        // A chunk the chunker would actually produce: a few sentences, well
        // inside the generation budget.
        // 350-odd characters, which is what `Chunker.defaultMaxChars` aims at —
        // about twenty-three seconds of speech. Measuring a short sentence
        // instead flatters the token loop and punishes the mel decoder, whose
        // cost is fixed per window however little of it is used.
        let text = """
            De schrijver liep langzaam door de oude stad en dacht aan zijn jeugd. \
            De grachten lagen stil onder een lage hemel, en in de verte sloeg een klok. \
            Hij herinnerde zich de winkel op de hoek, waar de vrouw met het grijze haar \
            altijd achter de toonbank stond en hem vroeg hoe het met zijn moeder ging. \
            Niets daarvan bestond nog, en toch liep hij er elke ochtend langs.
            """
        var options = SamplingOptions.multilingual
        options.maxTokens = 1200

        // Once to warm the models, then measured: the first call after a load
        // pays for Core ML's lazy specialisation and MLX's kernel JIT, and
        // would flatter nothing. Warmed with the *same* text so the mel
        // decoder window the measurement picks is the one that got warmed —
        // each fixed-size window specialises separately, once per process.
        _ = try await engine.speak(
            text, voice: voice, options: options, language: .named("nl")
        )

        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
        }

        // The two halves, separately: the token loop runs once per token, the
        // mel decoder once per window. Which of them dominates decides what
        // would be worth changing.
        let tokenClock = ContinuousClock.now
        let tokens = try await engine.generateSpeechTokens(
            for: text, voice: voice, options: options, language: .named("nl"),
            cancelled: { false }
        )
        let tokenTime = seconds(tokenClock.duration(to: .now))

        let audioClock = ContinuousClock.now
        let samples = try await engine.decodeToAudio(tokens: tokens, voice: voice)
        let audioTime = seconds(audioClock.duration(to: .now))

        let elapsed = tokenTime + audioTime
        let audio = Double(samples.count) / Double(engine.sampleRate)
        print(
            """
            SPLIT
              T3 token loop \(String(format: "%.2f", tokenTime))s for \(tokens.count) tokens             (\(String(format: "%.1f", Double(tokens.count) / tokenTime))/s)
              S3 mel+vocoder \(String(format: "%.2f", audioTime))s
            """
        )

        print(
            """
            MULTILINGUAL SPEED
              text          \(text.count) characters
              audio         \(String(format: "%.2f", audio))s
              wall          \(String(format: "%.2f", elapsed))s
              real-time     \(String(format: "%.2f", audio / elapsed))x
              per hour      \(String(format: "%.1f", elapsed / audio))h of compute per hour of audio
              speech tokens \(String(format: "%.1f", audio * 25)) at \
            \(String(format: "%.1f", audio * 25 / elapsed))/s
            """
        )
        #expect(audio > 5, "expected several seconds of audio, got \(audio)")
    }
}
