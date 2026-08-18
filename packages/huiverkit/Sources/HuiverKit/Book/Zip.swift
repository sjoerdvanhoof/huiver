import Compression
import Foundation

/// Just enough ZIP to read an EPUB.
///
/// An EPUB is a ZIP file, and Foundation has no ZIP reader. Rather than pull in
/// a dependency for it, this walks the central directory and inflates the
/// entries it is asked for. Only the two storage methods that appear in real
/// EPUBs are handled: stored (0) and deflate (8).
public struct Zip {
    public struct Entry {
        public let name: String
        let compression: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let headerOffset: Int
    }

    public enum ZipError: Error, LocalizedError {
        case notAZip
        case unsupportedCompression(UInt16)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: "Not a zip archive"
            case .unsupportedCompression(let method): "Unsupported zip compression method \(method)"
            case .corrupt(let what): "Damaged zip: \(what)"
            }
        }
    }

    private let data: Data
    public let entries: [Entry]

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public func contains(_ name: String) -> Bool {
        entries.contains { $0.name == name }
    }

    public func read(_ name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try read(entry)
    }

    public func read(_ entry: Entry) throws -> Data {
        // The local header repeats the name and extra-field lengths, and they
        // can differ from the central directory's, so the payload offset has to
        // be read from the local header rather than assumed.
        let header = entry.headerOffset
        guard header + 30 <= data.count, u32(header) == 0x0403_4b50 else {
            throw ZipError.corrupt("local header for \(entry.name)")
        }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressedSize <= data.count else {
            throw ZipError.corrupt("payload for \(entry.name)")
        }
        let payload = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.compression {
        case 0: return payload
        case 8: return try inflate(payload, expecting: entry.uncompressedSize)
        default: throw ZipError.unsupportedCompression(entry.compression)
        }
    }

    private func inflate(_ payload: Data, expecting size: Int) throws -> Data {
        // An empty file deflates to nothing useful; short-circuit rather than
        // ask the decoder for a zero-length buffer.
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source in
                guard let dst = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let src = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_decode_buffer(
                    dst, size, src, payload.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ZipError.corrupt("could not inflate") }
        return out.prefix(written)
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard data.count > 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record sits at the tail, after a comment
        // of up to 64 KB, so it is found by scanning backwards for its
        // signature rather than by arithmetic.
        var end = -1
        let earliest = max(0, data.count - 22 - 65_536)
        var probe = data.count - 22
        while probe >= earliest {
            if data.u32(at: probe) == 0x0605_4b50 { end = probe; break }
            probe -= 1
        }
        guard end >= 0 else { throw ZipError.notAZip }

        let count = Int(data.u16(at: end + 10))
        var offset = Int(data.u32(at: end + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(at: offset) == 0x0201_4b50 else {
                throw ZipError.corrupt("central directory entry")
            }
            let nameLength = Int(data.u16(at: offset + 28))
            let extraLength = Int(data.u16(at: offset + 30))
            let commentLength = Int(data.u16(at: offset + 32))
            let nameRange = (offset + 46)..<(offset + 46 + nameLength)
            guard nameRange.upperBound <= data.count else {
                throw ZipError.corrupt("entry name")
            }
            entries.append(
                Entry(
                    name: String(decoding: data.subdata(in: nameRange), as: UTF8.self),
                    compression: data.u16(at: offset + 10),
                    compressedSize: Int(data.u32(at: offset + 20)),
                    uncompressedSize: Int(data.u32(at: offset + 24)),
                    headerOffset: Int(data.u32(at: offset + 42))
                )
            )
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func u16(_ offset: Int) -> UInt16 { data.u16(at: offset) }
    private func u32(_ offset: Int) -> UInt32 { data.u32(at: offset) }
}

extension Data {
    func u16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
    }
}
