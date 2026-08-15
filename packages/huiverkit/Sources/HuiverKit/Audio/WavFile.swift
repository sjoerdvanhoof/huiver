import Foundation

/// Mono 24 kHz 16-bit WAV, read and written by hand.
///
/// There is no ffmpeg on the phone, so chapters stay as WAV rather than being
/// compressed: about 173 MB per hour, against 29 MB for the desktop app's
/// 64 kbps MP3. A ten-hour book is therefore around 1.7 GB.
///
/// 16-bit rather than float: it halves the file for no audible loss on speech,
/// and it is what `AVAudioFile` will hand back without conversion.
public enum WavFile {
    public static let sampleRate = 24000
    public static let bitsPerSample = 16
    static let headerSize = 44

    public static func data(from samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var out = Data(capacity: headerSize + samples.count * 2)
        let payload = samples.count * 2

        func append(_ string: String) { out.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { out.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
        func append16(_ value: Int) { out.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }

        append("RIFF")
        append32(36 + payload)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(sampleRate)
        append32(sampleRate * 2)  // byte rate
        append16(2)  // block align
        append16(bitsPerSample)
        append("data")
        append32(payload)

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            // Clamped, not wrapped: a sample past full scale should be a click
            // at worst, not a sign flip.
            pcm[index] = Int16(max(-32768, min(32767, (sample * 32767).rounded())))
        }
        pcm.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        return out
    }

    /// Samples back out of a file this wrote. Only the fixed layout above is
    /// understood — this is not a general WAV reader.
    public static func samples(from data: Data) -> [Float] {
        guard data.count > headerSize else { return [] }
        let count = (data.count - headerSize) / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: headerSize)
            for index in 0..<count {
                let value = base.advanced(by: index * 2).loadUnaligned(as: Int16.self)
                out[index] = Float(Int16(littleEndian: value)) / 32767
            }
        }
        return out
    }

    /// Duration without reading the samples, for a progress bar.
    public static func duration(ofFileAt url: URL) -> Double? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > headerSize
        else { return nil }
        return Double(size - headerSize) / 2 / Double(sampleRate)
    }
}
