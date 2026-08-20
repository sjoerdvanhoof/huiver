import Foundation
import Testing

@testable import HuiverKit

/// What AAC does to a chapter's audio, measured rather than assumed.
struct AudioCodecTests {
    /// Something speech-shaped: a low tone with a couple of harmonics, ramped
    /// in and out so it ends at silence the way a rendered chunk does.
    func tone(seconds: Double = 1.5, hz: Double = 180) -> [Float] {
        let count = Int(Double(WavFile.sampleRate) * seconds)
        return (0..<count).map { index in
            let t = Double(index) / Double(WavFile.sampleRate)
            let body = sin(2 * .pi * hz * t) * 0.6
                + sin(2 * .pi * hz * 2 * t) * 0.2
                + sin(2 * .pi * hz * 4 * t) * 0.1
            let ramp = min(1, min(t, seconds - t) / 0.005)  // 5 ms, as the renderer applies
            return Float(body * max(0, ramp))
        }
    }

    /// Noise, for the questions a periodic signal cannot answer — a tone lines
    /// up with itself at every period, so it cannot locate a delay.
    func noise(seconds: Double = 1.5) -> [Float] {
        var seed: UInt64 = 0x5eed
        return (0..<Int(Double(WavFile.sampleRate) * seconds)).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max) * 0.4
        }
    }

    func correlation(_ a: [Float], _ b: [Float], shift: Int = 0) -> Double {
        var dot = 0.0, energyA = 0.0, energyB = 0.0
        for index in 0..<min(a.count, b.count - shift) {
            let x = Double(a[index]), y = Double(b[index + shift])
            dot += x * y
            energyA += x * x
            energyB += y * y
        }
        return dot / max(1e-9, (energyA.squareRoot() * energyB.squareRoot()))
    }

    @Test("audio survives the round trip at the same length")
    func lengthIsPreserved() throws {
        let samples = tone()
        let decoded = try AudioCodec.decode(try AudioCodec.encode(samples))
        #expect(decoded.count == samples.count, "the container accounts for encoder priming")
    }

    /// The reason one file holds the whole transfer rather than one per chunk:
    /// nothing is shifted, so the chunk boundaries can be cut back out by
    /// sample count.
    @Test("nothing comes back offset in time")
    func noPrimingDelay() throws {
        let samples = noise()
        let decoded = try AudioCodec.decode(try AudioCodec.encode(samples))
        let aligned = correlation(samples, decoded)
        // If the decoder were handing back its priming, this would peak at a
        // shift of about 2112 samples instead of at zero.
        for shift in [512, 1024, 2112] {
            #expect(correlation(samples, decoded, shift: shift) < aligned)
        }
        #expect(aligned > 0.95, "correlation was \(aligned)")
    }

    @Test("what comes back still sounds like what went in")
    func waveformSurvives() throws {
        let samples = tone()
        let decoded = try AudioCodec.decode(try AudioCodec.encode(samples), samples: samples.count)
        // Correlation rather than sample equality: AAC is lossy, and the
        // question is whether this is the same waveform, not the same bits.
        #expect(correlation(samples, decoded) > 0.98)
    }

    /// The saving that makes syncing a book bearable. Measured over a length
    /// worth sending — the container costs about 33 kB whatever it holds, which
    /// is the whole reason a transfer is one file and not two hundred.
    @Test("a minute of speech compresses about six to one")
    func isSmaller() throws {
        let samples = tone(seconds: 60)
        let encoded = try AudioCodec.encode(samples)
        let wav = WavFile.data(from: samples).count
        #expect(Double(encoded.count) < Double(wav) / 5)
    }

    @Test("a chunk of pure silence still round-trips")
    func silence() throws {
        let samples = [Float](repeating: 0, count: WavFile.sampleRate / 10)
        let decoded = try AudioCodec.decode(
            try AudioCodec.encode(samples), samples: samples.count
        )
        #expect(decoded.count == samples.count)
        #expect(decoded.allSatisfy { abs($0) < 0.01 })
    }

    @Test("nothing to encode is an error rather than an empty file")
    func rejectsEmpty() {
        #expect(throws: AudioCodec.CodecError.self) { try AudioCodec.encode([]) }
    }
}

/// The wire format for a run of chunks, in both of its shapes.
struct ChunkPackTests {
    func pack(chunks: Int, samplesEach: Int = 6000, from start: Int = 0) -> Data {
        ChunkPack.pack(
            (0..<chunks).map { index in
                let samples = (0..<samplesEach).map { sample in
                    Float(sin(2 * .pi * 200 * Double(sample) / 24000) * 0.5)
                }
                return (start + index, WavFile.data(from: samples))
            }
        )
    }

    @Test("chunks come back with their indexes and lengths")
    func roundTrip() throws {
        let original = pack(chunks: 4, from: 6)
        let back = ChunkPack.unpack(try ChunkPack.wav(fromAAC: try ChunkPack.aac(from: original)))
        let before = ChunkPack.unpack(original)
        #expect(back.map(\.index) == [6, 7, 8, 9])
        #expect(
            back.map { WavFile.sampleCount(of: $0.data) }
                == before.map { WavFile.sampleCount(of: $0.data) }
        )
    }

    /// Chunk 3 must still be chunk 3 after the crossing: the audio is cut back
    /// out of one continuous stream, and an off-by-one here would put the
    /// second half of every chapter one file out of step.
    @Test("each chunk holds the audio it started with")
    func chunksAreNotShuffled() throws {
        let distinct = ChunkPack.pack(
            (0..<3).map { index in
                let hz = Double(150 + index * 200)
                let samples = (0..<6000).map { sample in
                    Float(sin(2 * .pi * hz * Double(sample) / 24000) * 0.5)
                }
                return (index, WavFile.data(from: samples))
            }
        )
        let back = ChunkPack.unpack(try ChunkPack.wav(fromAAC: try ChunkPack.aac(from: distinct)))
        for (index, chunk) in back.enumerated() {
            let samples = WavFile.samples(from: chunk.data)
            let hz = Double(150 + index * 200)
            let reference = (0..<samples.count).map { sample in
                Float(sin(2 * .pi * hz * Double(sample) / 24000) * 0.5)
            }
            var dot = 0.0, energyA = 0.0, energyB = 0.0
            for (x, y) in zip(samples, reference) {
                dot += Double(x) * Double(y)
                energyA += Double(x) * Double(x)
                energyB += Double(y) * Double(y)
            }
            let correlation = dot / max(1e-9, (energyA.squareRoot() * energyB.squareRoot()))
            #expect(correlation > 0.9, "chunk \(index) correlated \(correlation)")
        }
    }

    @Test("a whole chapter's worth is a fraction of the size")
    func compresses() throws {
        // 40 chunks of five seconds: a short chapter.
        let original = pack(chunks: 40, samplesEach: 5 * 24000)
        let compressed = try ChunkPack.aac(from: original)
        #expect(Double(compressed.count) < Double(original.count) / 5)
    }

    /// Anything that did not come out of `pack` is refused rather than
    /// "compressed" into an empty pack, which is how a chapter would arrive as
    /// nothing at all.
    @Test("a blob that is not a chunk pack is refused")
    func refusesForeignData() {
        #expect(throws: ChunkPack.PackError.self) {
            try ChunkPack.aac(from: Data(repeating: 42, count: 4000))
        }
        #expect(throws: ChunkPack.PackError.self) {
            try ChunkPack.wav(fromAAC: Data(repeating: 42, count: 4000))
        }
    }
}
