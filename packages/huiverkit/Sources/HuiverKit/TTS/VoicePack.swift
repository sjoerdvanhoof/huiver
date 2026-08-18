import Foundation

/// A voice, which for Chatterbox means a set of numbers derived from a
/// reference recording rather than a model of its own.
///
/// Nano has no voice roster: it clones whatever ten-to-fifteen second clip it
/// is handed. Turning a clip into these numbers needs three more networks — a
/// speech tokenizer, a speaker encoder and an x-vector model — so huiver does
/// it once on the Mac and ships the result. What arrives on the phone is about
/// 165 KB per voice, and the phone never sees the recording at all.
public struct Voice: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let detail: String
    /// Who this voice sounds like it is — a sentence about the reader rather
    /// than about the recording. `detail` says "warm, unhurried"; this says
    /// whose warmth it is. Optional: a voice without one just shows less.
    public var persona: String?

    /// T3 conditioning: who is speaking, and 375 speech tokens of them saying
    /// the reference passage.
    public let speakerEmbedding: [Float]
    public let condPromptTokens: [Int32]

    /// S3Gen conditioning: the same clip as speech tokens and mel frames, plus
    /// an x-vector. Both lengths are fixed by the export, which is what lets
    /// the mel decoder be a single fixed-shape Core ML model.
    public let promptTokens: [Int32]
    public let promptFeatures: [Float]
    public let xvector: [Float]

    /// A pre-rendered sample of this voice, if one shipped. Rendered on the Mac
    /// by `export_previews.py`: synthesising it on demand would mean a
    /// fifteen-second wait and a warm engine just to audition a voice.
    public var previewURL: URL?
}

public enum VoicePack {
    static let magic: UInt32 = 0x49_4f_56_48  // "HVOI" little-endian
    static let version: UInt32 = 1

    struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let detail: String
            let file: String
            /// Absent until `export_previews.py` has been run for this voice.
            let preview: String?
            /// Absent in manifests written before personas existed.
            let persona: String?
        }
        let voices: [Entry]
    }

    public enum LoadError: Error, LocalizedError {
        case noManifest(URL)
        case badMagic(String)
        case badVersion(String, UInt32)
        case truncated(String)

        public var errorDescription: String? {
            switch self {
            case .noManifest(let url):
                "No voices.json in \(url.path). Run: bun run ios:voices"
            case .badMagic(let file): "\(file) is not a huiver voice file"
            case .badVersion(let file, let v): "\(file) is voice format v\(v); this app reads v\(version)"
            case .truncated(let file): "\(file) ended early"
            }
        }
    }

    /// Read every voice listed in `voices.json` in the given directory.
    public static func load(from directory: URL) throws -> [Voice] {
        let manifestURL = directory.appendingPathComponent("voices.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LoadError.noManifest(directory)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return try manifest.voices.map { entry in
            let blob = try Data(contentsOf: directory.appendingPathComponent(entry.file))
            var voice = try decode(blob, entry: entry)
            if let preview = entry.preview {
                let url = directory.appendingPathComponent(preview)
                // Only offered if the file is really there, so a manifest that
                // mentions a preview the build forgot to copy does not leave a
                // play button that does nothing.
                if FileManager.default.fileExists(atPath: url.path) { voice.previewURL = url }
            }
            return voice
        }
    }

    static func decode(_ data: Data, entry: Manifest.Entry) throws -> Voice {
        var reader = Reader(data: data, file: entry.file)
        guard try reader.u32() == magic else { throw LoadError.badMagic(entry.file) }
        let version = try reader.u32()
        guard version == Self.version else { throw LoadError.badVersion(entry.file, version) }

        let speakerCount = Int(try reader.u32())
        let condCount = Int(try reader.u32())
        let promptCount = Int(try reader.u32())
        let featFrames = Int(try reader.u32())
        let melDim = Int(try reader.u32())
        let xvectorDim = Int(try reader.u32())

        return Voice(
            id: entry.id,
            name: entry.name,
            detail: entry.detail,
            persona: entry.persona,
            speakerEmbedding: try reader.floats(speakerCount),
            condPromptTokens: try reader.int32s(condCount),
            promptTokens: try reader.int32s(promptCount),
            promptFeatures: try reader.floats(featFrames * melDim),
            xvector: try reader.floats(xvectorDim)
        )
    }

    /// A little-endian cursor. The file is written by `export_voices.py`, so the
    /// two layouts have to be read side by side when either changes.
    private struct Reader {
        let data: Data
        let file: String
        var offset = 0

        mutating func take(_ count: Int) throws -> Data {
            guard offset + count <= data.count else { throw LoadError.truncated(file) }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func u32() throws -> UInt32 {
            try take(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        mutating func floats(_ count: Int) throws -> [Float] {
            try take(count * 4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        mutating func int32s(_ count: Int) throws -> [Int32] {
            try take(count * 4).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        }
    }
}
