import Foundation
import Testing

@testable import HuiverKit

/// The loudness meter, against `pyloudnorm`.
///
/// The numbers below came from `pyloudnorm.Meter(24000).integrated_loudness`,
/// which is the meter `ChatterboxTurboTTS.norm_loudness` uses and therefore the
/// one every voice this project has ever cloned was normalised by. The signals
/// are written out here rather than stored as a fixture: a formula both sides
/// can evaluate is a smaller thing to keep true than a megabyte of samples.
///
/// Reproduce with:
///
/// ```python
/// import numpy as np, pyloudnorm as ln
/// n = np.arange(3 * 24000)
/// tone = 0.5 * np.sin(2 * np.pi * 440 * n / 24000)
/// ln.Meter(24000).integrated_loudness(tone)   # -9.757343
/// ```
struct LoudnessTests {
    private let rate = 24000

    private func tone(_ seconds: Double, _ amplitude: Double, _ frequency: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map {
            Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(rate)))
        }
    }

    /// A tenth of a LU: far inside the 0.1 dB the spec allows a meter, and far
    /// inside anything a clone could hear.
    private let tolerance = 0.01

    @Test("a tone measures what pyloudnorm measures")
    func tonesMatch() {
        let measured = Loudness.integrated(tone(3, 0.5, 440), sampleRate: rate)
        #expect(abs(measured - -9.757343) < tolerance)
    }

    /// Two tones either side of the shelf, so a meter that skipped the
    /// K-weighting — or got its corner wrong — would disagree here and not above.
    @Test("the K-weighting is the spec's, not a plain RMS")
    func weightingMatches() {
        let signal = zip(tone(3, 0.4, 440), tone(3, 0.3, 90)).map(+)
        let measured = Loudness.integrated(signal, sampleRate: rate)
        #expect(abs(measured - -10.208590) < tolerance)
    }

    /// Two seconds of speech-level tone and four of near-silence. Without the
    /// relative gate the quiet tail drags the answer down by several LU, which
    /// is exactly the case a recording with a long pause in it presents.
    @Test("the quiet tail is gated out, not averaged in")
    func gatingMatches() {
        let signal = tone(2, 0.5, 300) + tone(4, 0.002, 300)
        let measured = Loudness.integrated(signal, sampleRate: rate)
        #expect(abs(measured - -10.192218) < tolerance)
        // The ungated mean of the same signal is far quieter; if this ever
        // starts passing by accident, that is the number it would have become.
        #expect(measured > -13)
    }

    @Test("normalising hits the target it was given")
    func normalisingHitsTheTarget() {
        let quiet = tone(3, 0.05, 440)
        let normalised = Loudness.normalised(quiet, to: -27, sampleRate: rate)
        #expect(abs(Loudness.integrated(normalised, sampleRate: rate) - -27) < tolerance)
    }

    /// Nothing to measure and nothing to scale. A gain derived from silence is
    /// an infinity, and multiplying a clip by it is worse than leaving it.
    @Test("silence is left alone rather than amplified")
    func silenceIsLeftAlone() {
        let silent = [Float](repeating: 0, count: 3 * 24000)
        #expect(Loudness.integrated(silent, sampleRate: rate) == Loudness.silence)
        #expect(Loudness.normalised(silent, to: -27, sampleRate: rate).allSatisfy { $0 == 0 })
    }

    /// Shorter than one 400 ms block: the spec has nothing to say, so neither
    /// does this — and it must not divide by zero on the way to saying it.
    @Test("a clip shorter than a block measures as silence")
    func tooShortToMeasure() {
        #expect(Loudness.integrated(tone(0.2, 0.5, 440), sampleRate: rate) == Loudness.silence)
    }
}
