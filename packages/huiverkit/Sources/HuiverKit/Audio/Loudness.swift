import Foundation

/// How loud a recording is, by ITU-R BS.1770, and the gain that fixes it.
///
/// Nano normalises every reference clip to −27 LUFS before cloning from it —
/// `ChatterboxTurboTTS.norm_loudness`, which the multilingual checkpoint has no
/// equivalent of. It is one number times the whole clip, so it stays out of the
/// Core ML package: the measurement is two IIR filters and a gated mean, and
/// Core ML has no IIR. Doing it here also means the app can say what it did.
///
/// It matters more than "a gain" sounds. The conditioning mel the decoder is
/// given is a *log* magnitude, so the clip's level lands in it as an offset,
/// and a clone made from an unnormalised clip drifts: measured against the
/// Python pipeline, the speaker embedding fell to 0.977 cosine and the mel to
/// 0.998, against 1.000000 for both once this is applied.
///
/// This is the spec's algorithm rather than an approximation of it — the
/// K-weighting pair, 400 ms blocks at 75% overlap, the absolute gate at −70
/// LUFS and the relative gate 10 LU below the ungated mean. `LoudnessTests`
/// holds it to `pyloudnorm`, which is what `verify_clone.py` measures with.
public enum Loudness {
    /// Quieter than this and there is nothing to measure: every block fell
    /// below the absolute gate, so the answer is silence rather than a number.
    public static let silence = -Double.infinity

    /// Integrated loudness in LUFS, or `silence`.
    public static func integrated(_ samples: [Float], sampleRate: Int) -> Double {
        let rate = Double(sampleRate)
        let blockSeconds = 0.4
        // 75% overlap, so a block starts every 100 ms.
        let step = 0.25
        let duration = Double(samples.count) / rate
        guard duration >= blockSeconds else { return silence }

        let weighted = highPass(highShelf(samples, rate: rate), rate: rate)

        let blocks = Int((duration - blockSeconds) / (blockSeconds * step) + 0.5) + 1
        let blockSamples = blockSeconds * rate
        var meanSquares: [Double] = []
        var loudnesses: [Double] = []
        meanSquares.reserveCapacity(blocks)
        loudnesses.reserveCapacity(blocks)
        for block in 0..<blocks {
            let lower = Int(blockSeconds * (Double(block) * step) * rate)
            let upper = min(
                weighted.count, Int(blockSeconds * (Double(block) * step + 1) * rate)
            )
            guard lower < upper else { continue }
            var sum = 0.0
            for index in lower..<upper { sum += weighted[index] * weighted[index] }
            let meanSquare = sum / blockSamples
            meanSquares.append(meanSquare)
            loudnesses.append(-0.691 + 10 * log10(meanSquare))
        }
        guard !meanSquares.isEmpty else { return silence }

        // The absolute gate first, then a relative one ten below whatever
        // survived it: the point is to measure the speech and not the pauses.
        let absoluteGate = -70.0
        let aboveAbsolute = loudnesses.indices.filter { loudnesses[$0] >= absoluteGate }
        guard !aboveAbsolute.isEmpty else { return silence }
        let ungatedMean =
            aboveAbsolute.reduce(0.0) { $0 + meanSquares[$1] } / Double(aboveAbsolute.count)
        let relativeGate = -0.691 + 10 * log10(ungatedMean) - 10

        let kept = loudnesses.indices.filter {
            loudnesses[$0] > relativeGate && loudnesses[$0] > absoluteGate
        }
        guard !kept.isEmpty else { return silence }
        let mean = kept.reduce(0.0) { $0 + meanSquares[$1] } / Double(kept.count)
        guard mean > 0 else { return silence }
        return -0.691 + 10 * log10(mean)
    }

    /// The recording at `target` LUFS. Silence is returned untouched: there is
    /// no gain that makes nothing into something, and `Float.infinity` samples
    /// are worse than a quiet clone.
    public static func normalised(
        _ samples: [Float], to target: Double, sampleRate: Int
    ) -> [Float] {
        let measured = integrated(samples, sampleRate: sampleRate)
        guard measured.isFinite else { return samples }
        let gain = Float(pow(10, (target - measured) / 20))
        guard gain.isFinite, gain > 0 else { return samples }
        return samples.map { $0 * gain }
    }

    // MARK: - K-weighting

    /// The shelf that stands in for a head: +4 dB above 1.5 kHz.
    private static func highShelf(_ samples: [Float], rate: Double) -> [Double] {
        let gain = 4.0
        let q = 1 / 2.0.squareRoot()
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * 1500 / rate
        let alpha = sin(w0) / (2 * q)
        let cosine = cos(w0)
        let rootA = a.squareRoot()

        let b0 = a * ((a + 1) + (a - 1) * cosine + 2 * rootA * alpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
        let b2 = a * ((a + 1) + (a - 1) * cosine - 2 * rootA * alpha)
        let a0 = (a + 1) - (a - 1) * cosine + 2 * rootA * alpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosine)
        let a2 = (a + 1) - (a - 1) * cosine - 2 * rootA * alpha
        return biquad(samples.map(Double.init), b: (b0 / a0, b1 / a0, b2 / a0), a: (a1 / a0, a2 / a0))
    }

    /// And the high-pass below it, at 38 Hz.
    private static func highPass(_ samples: [Double], rate: Double) -> [Double] {
        let q = 0.5
        let w0 = 2 * Double.pi * 38 / rate
        let alpha = sin(w0) / (2 * q)
        let cosine = cos(w0)

        let b0 = (1 + cosine) / 2
        let b1 = -(1 + cosine)
        let b2 = (1 + cosine) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosine
        let a2 = 1 - alpha
        return biquad(samples, b: (b0 / a0, b1 / a0, b2 / a0), a: (a1 / a0, a2 / a0))
    }

    /// Direct form I with zero initial conditions, which is what `lfilter`
    /// does and therefore what the reference measurement did.
    private static func biquad(
        _ input: [Double], b: (Double, Double, Double), a: (Double, Double)
    ) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in input.indices {
            let x0 = input[index]
            let y0 = b.0 * x0 + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
            output[index] = y0
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }
        return output
    }
}
