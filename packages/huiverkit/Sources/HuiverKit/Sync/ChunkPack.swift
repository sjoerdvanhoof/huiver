import Foundation

/// Several chunk files in one blob: `u32 count | (u32 index | u32 length |
/// bytes)*`. Little-endian, like the framing.
///
/// One blob per requested range rather than one transfer per chunk, because a
/// chapter is a couple of hundred chunks and each transfer costs a header, a
/// hash and two control frames.
///
/// The bytes inside are WAV, which is what both libraries store. `aac(from:)`
/// swaps them for something a sixth of the size for the crossing only — see
/// `AudioCodec` for why that stops at the wire.
enum ChunkPack {
    static func pack(_ chunks: [(index: Int, data: Data)]) -> Data {
        var out = Data()
        append(UInt32(chunks.count), to: &out)
        for chunk in chunks {
            append(UInt32(chunk.index), to: &out)
            append(UInt32(chunk.data.count), to: &out)
            out.append(chunk.data)
        }
        return out
    }

    static func unpack(_ data: Data) -> [(index: Int, data: Data)] {
        var offset = data.startIndex
        guard let count = readU32(data, &offset) else { return [] }
        var out: [(Int, Data)] = []
        for _ in 0..<count {
            guard let index = readU32(data, &offset),
                  let length = readU32(data, &offset),
                  data.distance(from: offset, to: data.endIndex) >= Int(length)
            else { return out }
            let end = data.index(offset, offsetBy: Int(length))
            out.append((Int(index), Data(data[offset..<end])))
            offset = end
        }
        return out
    }

    // MARK: - The compressed form

    /// The same chunks as one AAC file: `u32 count | (u32 index | u32
    /// samples)* | u32 length | bytes`.
    ///
    /// One file for the whole transfer rather than one per chunk, and the
    /// sample counts carried separately so the receiver can cut the decoded
    /// stream back into the files the library expects. `AudioCodec` explains
    /// why it is shaped this way; the short version is that an MPEG-4
    /// container costs 33 kB and a chunk of speech does not.
    ///
    /// A separate format rather than a version bump on the one above: only a
    /// peer that said it understands AAC is ever sent one of these, so there is
    /// no older reader to keep happy.
    static func aac(from wavPack: Data) throws -> Data {
        let chunks = unpack(wavPack)
        // Only something this could have produced is worth compressing. Without
        // the check, a blob that is not a chunk pack silently "compresses" to an
        // empty one — which is a chapter arriving as nothing at all.
        guard !chunks.isEmpty, pack(chunks) == wavPack else { throw PackError.notAChunkPack }

        var samples: [Float] = []
        var header = Data()
        append(UInt32(chunks.count), to: &header)
        for chunk in chunks {
            let decoded = WavFile.samples(from: chunk.data)
            append(UInt32(chunk.index), to: &header)
            append(UInt32(decoded.count), to: &header)
            samples.append(contentsOf: decoded)
        }

        let encoded = try AudioCodec.encode(samples)
        var out = header
        append(UInt32(encoded.count), to: &out)
        out.append(encoded)
        return out
    }

    /// Back to a pack of WAV, cut where the chunks were.
    ///
    /// The cuts are exact because the sample counts came with it: an AAC frame
    /// that straddles two chunks smears a little across the boundary, but a
    /// chunk ends at digital silence by construction, so there is nothing there
    /// to smear.
    static func wav(fromAAC data: Data) throws -> Data {
        var offset = data.startIndex
        guard let count = readU32(data, &offset) else { throw PackError.truncated }

        var layout: [(index: Int, samples: Int)] = []
        for _ in 0..<count {
            guard let index = readU32(data, &offset), let samples = readU32(data, &offset) else {
                throw PackError.truncated
            }
            layout.append((Int(index), Int(samples)))
        }
        guard let length = readU32(data, &offset),
              data.distance(from: offset, to: data.endIndex) >= Int(length)
        else { throw PackError.truncated }

        let end = data.index(offset, offsetBy: Int(length))
        let total = layout.reduce(0) { $0 + $1.samples }
        let samples = try AudioCodec.decode(Data(data[offset..<end]), samples: total)

        var chunks: [(index: Int, data: Data)] = []
        var cursor = 0
        for entry in layout {
            let slice = Array(samples[cursor..<(cursor + entry.samples)])
            chunks.append((entry.index, WavFile.data(from: slice)))
            cursor += entry.samples
        }
        return pack(chunks)
    }

    enum PackError: Error {
        /// Handed something that did not come out of `pack`.
        case notAChunkPack
        case truncated
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readU32(_ data: Data, _ offset: inout Data.Index) -> UInt32? {
        guard data.distance(from: offset, to: data.endIndex) >= 4 else { return nil }
        let end = data.index(offset, offsetBy: 4)
        let value = data[offset..<end].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        offset = end
        return UInt32(littleEndian: value)
    }
}
