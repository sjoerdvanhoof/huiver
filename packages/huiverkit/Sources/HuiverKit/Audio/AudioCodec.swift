import AVFoundation
import Foundation

/// PCM in, AAC out, and back again — for the wire only.
///
/// Audio is stored as WAV on both devices and always will be: the library is a
/// folder of one file per chunk, and the player, the chunk map and the cleanup
/// sweep all assume it. What this changes is only what crosses between them,
/// where 173 MB an hour is the difference between syncing a book and giving up
/// on it.
///
/// Transcoding on the wire rather than in the library is deliberate, and so is
/// doing it a transfer at a time rather than a chunk at a time. Two reasons,
/// both measured:
///
/// * **Priming.** An AAC encoder delays its output — 2112 samples with this
///   one. An MPEG-4 container records that and the decoder gives back exactly
///   what went in; raw ADTS does not, and every chunk would come back 88 ms
///   late. That is a read-along drifting out of step, chunk after chunk.
/// * **Overhead.** The container costs about 33 kB whatever it holds, which is
///   more than a five-second chunk of speech compresses to. One file per
///   transfer amortises it into nothing; one per chunk would make small
///   chapters *larger* than the WAV they replace.
public enum AudioCodec {
    /// 64 kbps mono. Speech at 24 kHz has nothing above 12 kHz to lose, and
    /// that is about a sixth of what 16-bit PCM costs.
    public static let bitRate = 64_000

    public enum CodecError: Error, LocalizedError {
        case unreadable
        case emptyAudio

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "The audio could not be read."
            case .emptyAudio: return "The audio was empty."
            }
        }
    }

    /// One run of samples as an AAC-in-MPEG-4 file.
    public static func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty else { throw CodecError.emptyAudio }

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // The writer lives in its own scope, and it matters: an `AVAudioFile`
        // finishes the container when it goes away. Reading the file while the
        // writer is still alive gets an MPEG-4 with no sample table, which
        // fails to open later — a long way from here.
        try {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Double(WavFile.sampleRate),
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: bitRate,
                ]
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw CodecError.unreadable
            }
            samples.withUnsafeBufferPointer {
                channel.update(from: $0.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }()

        return try Data(contentsOf: url)
    }

    /// The samples back.
    ///
    /// `expected` is enforced rather than trusted. The container's gapless
    /// metadata gets this right today, on both platforms and for every length
    /// measured — but "the audio came back 40 ms longer than the chunk map
    /// says" is a silent, cumulative fault, and one clamp is cheaper than
    /// finding out from a read-along that walks.
    public static func decode(_ data: Data, samples expected: Int? = nil) throws -> [Float] {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)

        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frames
        ) else {
            throw CodecError.emptyAudio
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CodecError.unreadable }

        var samples = [Float](UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        if let expected {
            if samples.count > expected {
                samples.removeLast(samples.count - expected)
            } else if samples.count < expected {
                samples.append(contentsOf: [Float](repeating: 0, count: expected - samples.count))
            }
        }
        return samples
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("huiver-\(UUID().uuidString).m4a")
    }
}
