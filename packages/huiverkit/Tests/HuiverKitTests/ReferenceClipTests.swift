import Foundation
import Testing

@testable import HuiverKit

/// Choosing the ten seconds a clone is built from.
struct ReferenceClipTests {
    /// Speech-shaped audio: a tone with an envelope, so energy varies the way a
    /// sentence's does.
    func speech(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(Double(ReferenceClip.sampleRate) * seconds)
        return (0..<count).map { index in
            let t = Double(index) / Double(ReferenceClip.sampleRate)
            let envelope = 0.6 + 0.4 * sin(2 * .pi * 2.5 * t)
            return Float(sin(2 * .pi * 180 * t) * envelope) * amplitude
        }
    }

    func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(Double(ReferenceClip.sampleRate) * seconds))
    }

    @Test("the result is always exactly what the model was traced for")
    func alwaysTenSeconds() {
        for recording in [speech(seconds: 3), speech(seconds: 10), speech(seconds: 25)] {
            #expect(ReferenceClip.prepare(recording).samples.count == ReferenceClip.samples)
        }
    }

    @Test("silence at the ends is trimmed away")
    func trimsSilence() {
        let recording = silence(seconds: 2) + speech(seconds: 12) + silence(seconds: 3)
        let choice = ReferenceClip.prepare(recording)
        // Twelve seconds of speech, give or take a frame of the trim's
        // resolution.
        #expect(choice.availableSeconds > 11.5)
        #expect(choice.availableSeconds < 12.5)
        // And the kept audio starts inside the speech, not in the lead-in.
        #expect(choice.peak > 0.1)
    }

    /// The reason the window is chosen rather than taken from the front: a
    /// recording that opens with a false start should contribute its speech.
    ///
    /// A false start much quieter than the take is *trimmed* rather than
    /// stepped over — 0.02 against 0.4 is 26 dB down, past the threshold — so
    /// what this pins down is that the kept audio comes from the loud part
    /// either way, and that the offset is reported against the recording.
    @Test("the take is found, not the false start")
    func picksTheLoudestWindow() {
        let quiet = speech(seconds: 6, amplitude: 0.02)
        let loud = speech(seconds: 12, amplitude: 0.4)
        let choice = ReferenceClip.prepare(quiet + loud)
        #expect(choice.startSeconds > 5, "started at \(choice.startSeconds)s")
        #expect(choice.peak > 0.3)
        #expect(choice.availableSeconds < 13, "the quiet lead-in is not speech")
    }

    /// And the case where the trim keeps everything, so the window has to do
    /// the choosing: a pause in the middle of a take.
    @Test("a pause in the middle is stepped over")
    func stepsOverAPause() {
        let recording = speech(seconds: 4, amplitude: 0.35)
            + silence(seconds: 3)
            + speech(seconds: 11, amplitude: 0.4)
        let choice = ReferenceClip.prepare(recording)
        #expect(choice.startSeconds > 5, "started at \(choice.startSeconds)s")
    }

    @Test("a recording shorter than ten seconds is padded, not stretched")
    func padsShortRecordings() {
        let choice = ReferenceClip.prepare(speech(seconds: 4))
        #expect(choice.samples.count == ReferenceClip.samples)
        #expect(choice.availableSeconds < 4.5)
        // The tail is the padding.
        #expect(choice.samples.suffix(ReferenceClip.sampleRate).allSatisfy { $0 == 0 })
    }

    @Test("silence in, silence out — and the caller can tell")
    func allSilence() {
        let choice = ReferenceClip.prepare(silence(seconds: 12))
        #expect(choice.samples.count == ReferenceClip.samples)
        #expect(choice.peak == 0, "a caller must be able to refuse this")
    }

    @Test("decibels are measured against the loudest frame")
    func decibelsAreRelative() {
        let frames = ReferenceClip.decibels(speech(seconds: 5))
        #expect(frames.max()! <= 0.001, "the peak frame is the zero point")
        #expect(frames.count > 100)
    }
}
