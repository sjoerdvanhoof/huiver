import Accelerate
import Foundation

/// Turning a recording into the ten seconds a clone is built from.
///
/// The model is exported for exactly ten seconds at 24 kHz, so something has to
/// choose *which* ten seconds — and that choice matters more to how a clone
/// sounds than anything downstream of it. A reference clip should be continuous
/// speech by one person at a steady level: silence teaches the model that this
/// voice pauses, and a clipped shout teaches it to shout.
///
/// Three steps, in this order:
///
/// 1. **Trim** the silence at each end, the way `librosa.effects.trim(top_db:20)`
///    does — because the voice encoder upstream trims too, and a clip that keeps
///    its leading silence produces a measurably different speaker embedding.
/// 2. **Choose** the loudest continuous ten seconds of what is left, so a
///    recording with a pause in the middle contributes its speech rather than
///    its pause.
/// 3. **Fit** to exactly ten seconds, padding with silence only if there is not
///    enough audio to fill it.
public enum ReferenceClip {
    /// What the exported cloner is traced for.
    public static let sampleRate = 24000
    public static let seconds = 10
    public static var samples: Int { sampleRate * seconds }

    /// Frames the trim measures loudness over: 2048 samples with a 512 hop, as
    /// librosa's defaults are.
    static let frameLength = 2048
    static let hopLength = 512

    /// How far below the peak counts as silence, in decibels. librosa's
    /// `top_db` default is 60; the voice encoder asks for 20, which is what
    /// matters here because that is the trim being matched.
    public static let topDecibels: Float = 20

    /// The ten seconds to clone from, and where they came from.
    public struct Choice: Sendable, Equatable {
        public var samples: [Float]
        /// Where in the *original recording* the kept audio starts, in
        /// seconds — so a screen can say "we used 0:06 to 0:16" rather than
        /// leaving the listener to guess. Relative to the recording rather than
        /// to the trimmed audio, which is the same number only when nothing was
        /// trimmed.
        public var startSeconds: Double
        /// How much speech there was to choose from, after trimming.
        public var availableSeconds: Double
        /// Peak amplitude of the kept audio, so a caller can complain about a
        /// recording that is too quiet or clipped.
        public var peak: Float
    }

    public static func prepare(_ recording: [Float]) -> Choice {
        let (trimmed, trimOffset) = trim(recording)
        let available = Double(trimmed.count) / Double(sampleRate)
        let (window, offset) = loudestWindow(trimmed)
        var kept = window
        if kept.count < samples {
            kept += [Float](repeating: 0, count: samples - kept.count)
        }
        return Choice(
            samples: kept,
            startSeconds: Double(trimOffset + offset) / Double(sampleRate),
            availableSeconds: available,
            peak: window.map(abs).max() ?? 0
        )
    }

    // MARK: - The steps

    /// Frame energies in decibels relative to the loudest frame.
    static func decibels(_ audio: [Float]) -> [Float] {
        guard audio.count >= frameLength else {
            let energy = audio.reduce(0) { $0 + $1 * $1 } / Float(max(audio.count, 1))
            return [10 * log10f(max(energy, 1e-20))]
        }
        var out: [Float] = []
        out.reserveCapacity((audio.count - frameLength) / hopLength + 1)
        var start = 0
        while start + frameLength <= audio.count {
            var energy: Float = 0
            audio.withUnsafeBufferPointer { buffer in
                let base = buffer.baseAddress! + start
                vDSP_measqv(base, 1, &energy, vDSP_Length(frameLength))
            }
            out.append(10 * log10f(max(energy, 1e-20)))
            start += hopLength
        }
        let peak = out.max() ?? 0
        return out.map { $0 - peak }
    }

    /// Silence off both ends, and how much came off the front.
    static func trim(_ audio: [Float]) -> ([Float], Int) {
        let frames = decibels(audio)
        guard let first = frames.firstIndex(where: { $0 > -topDecibels }),
              let last = frames.lastIndex(where: { $0 > -topDecibels })
        else { return (audio, 0) }  // all silence: let the caller complain
        let start = first * hopLength
        let end = min(audio.count, last * hopLength + frameLength)
        guard start < end else { return (audio, 0) }
        return (Array(audio[start..<end]), start)
    }

    /// The loudest ten seconds, by mean energy, stepped a quarter-second at a
    /// time — fine enough to skip a pause, coarse enough to be free.
    static func loudestWindow(_ audio: [Float]) -> ([Float], Int) {
        guard audio.count > samples else { return (audio, 0) }
        let step = sampleRate / 4
        var best = 0
        var bestEnergy: Float = -1
        var start = 0
        while start + samples <= audio.count {
            var energy: Float = 0
            audio.withUnsafeBufferPointer { buffer in
                vDSP_measqv(buffer.baseAddress! + start, 1, &energy, vDSP_Length(samples))
            }
            if energy > bestEnergy {
                bestEnergy = energy
                best = start
            }
            start += step
        }
        return (Array(audio[best..<(best + samples)]), best)
    }
}
