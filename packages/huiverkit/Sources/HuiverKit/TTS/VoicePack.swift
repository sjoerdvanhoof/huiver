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

    /// The language the reference clip was recorded in.
    ///
    /// Not a restriction — the model will read any language in any voice — but
    /// the accent comes from the clip, so a Dutch book in an English voice is an
    /// English speaker reading Dutch, and sounds like it. This is what lets the
    /// app pick a reader who belongs to the book. Absent in voice packs written
    /// before it existed, which were all English.
    public var language: String?

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
            /// Absent in packs written before voices had a language, all of
            /// which were English.
            let language: String?
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
            case .badMagic(let file): "\(file) is not a Narcisse voice file"
            case .badVersion(let file, let v): "\(file) is voice format v\(v); this app reads v\(version)"
            case .truncated(let file): "\(file) ended early"
            }
        }
    }

    /// Read the voices in `directory`, and any the listener has recorded.
    ///
    /// Two directories rather than one: the pack that ships is inside the app
    /// bundle and is read-only, and a voice cloned on this machine has to live
    /// somewhere writable. A recorded voice with the same id as a shipped one
    /// wins — that is what re-recording means.
    public static func load(from directory: URL, plus recorded: URL?) throws -> [Voice] {
        let shipped = try load(from: directory)
        guard let recorded, FileManager.default.fileExists(
            atPath: recorded.appendingPathComponent("voices.json").path
        ) else { return shipped }
        // A broken recorded pack must not take the shipped voices down with it.
        let mine = (try? load(from: recorded)) ?? []
        let replaced = Set(mine.map(\.id))
        return shipped.filter { !replaced.contains($0.id) } + mine
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
            language: entry.language,
            speakerEmbedding: try reader.floats(speakerCount),
            condPromptTokens: try reader.int32s(condCount),
            promptTokens: try reader.int32s(promptCount),
            promptFeatures: try reader.floats(featFrames * melDim),
            xvector: try reader.floats(xvectorDim)
        )
    }

    // MARK: - Writing one

    /// Write a voice and add it to `directory`'s manifest.
    ///
    /// The same layout `export_voices.py` writes, because the app has to read
    /// both: a voice cloned here and a voice that shipped are the same kind of
    /// thing, and nothing downstream should be able to tell them apart.
    public static func write(_ voice: Voice, to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = "\(voice.id).voice"
        var data = Data()
        func u32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: withUnsafeBytes(of: magic.littleEndian, Array.init))
        u32(Int(version))
        u32(voice.speakerEmbedding.count)
        u32(voice.condPromptTokens.count)
        u32(voice.promptTokens.count)
        // The header carries frames and mel width separately; the payload is
        // frames × width floats.
        let melDimension = 80
        u32(voice.promptFeatures.count / melDimension)
        u32(melDimension)
        u32(voice.xvector.count)

        func floats(_ values: [Float]) {
            values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        func int32s(_ values: [Int32]) {
            values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        floats(voice.speakerEmbedding)
        int32s(voice.condPromptTokens)
        int32s(voice.promptTokens)
        floats(voice.promptFeatures)
        floats(voice.xvector)

        // Written whole and moved into place: a half-written voice file that the
        // manifest already mentions would fail every load from then on.
        let destination = directory.appendingPathComponent(file)
        try data.write(to: destination, options: .atomic)
        try updateManifest(in: directory, with: voice, file: file)
    }

    /// Add or update a manifest entry for a voice whose `.voice` file is
    /// already in `directory`.
    ///
    /// How a voice that arrived over sync becomes loadable: the wire delivers
    /// an id and a blob, and a blob the manifest does not mention is invisible
    /// to `load` — and, worse, re-requested by every future session, because
    /// the manifest is also what the diff compares.
    public static func register(
        id: String, name: String, detail: String, in directory: URL
    ) throws {
        var manifest = readManifest(in: directory)
        let previewFile = "\(id).preview.wav"
        let hasPreview = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(previewFile).path
        )
        var entry = WritableManifest.Entry(
            id: id, name: name, detail: detail, file: "\(id).voice",
            preview: hasPreview ? previewFile : nil, persona: nil, language: nil
        )
        if let index = manifest.voices.firstIndex(where: { $0.id == id }) {
            // Keep whatever a fuller entry already knew.
            entry.persona = manifest.voices[index].persona
            entry.language = manifest.voices[index].language
            manifest.voices[index] = entry
        } else {
            manifest.voices.append(entry)
        }
        try writeManifest(manifest, in: directory)
    }

    /// Remove a recorded voice and forget it in the manifest.
    public static func remove(id: String, from directory: URL) throws {
        var manifest = readManifest(in: directory)
        manifest.voices.removeAll { $0.id == id }
        try writeManifest(manifest, in: directory)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).voice")
        )
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id).preview.wav")
        )
    }

    /// The manifest as something writable. `Manifest` itself is decode-only
    /// because everything else only ever reads one.
    struct WritableManifest: Codable {
        struct Entry: Codable {
            var id: String
            var name: String
            var detail: String
            var file: String
            var preview: String?
            var persona: String?
            var language: String?
        }
        var voices: [Entry] = []
    }

    static func readManifest(in directory: URL) -> WritableManifest {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("voices.json")),
              let manifest = try? JSONDecoder().decode(WritableManifest.self, from: data)
        else { return WritableManifest() }
        return manifest
    }

    static func writeManifest(_ manifest: WritableManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("voices.json"), options: .atomic
        )
    }

    private static func updateManifest(
        in directory: URL, with voice: Voice, file: String
    ) throws {
        var manifest = readManifest(in: directory)
        let entry = WritableManifest.Entry(
            id: voice.id,
            name: voice.name,
            detail: voice.detail,
            file: file,
            preview: voice.previewURL?.lastPathComponent,
            persona: voice.persona,
            language: voice.language
        )
        if let index = manifest.voices.firstIndex(where: { $0.id == voice.id }) {
            manifest.voices[index] = entry
        } else {
            manifest.voices.append(entry)
        }
        try writeManifest(manifest, in: directory)
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
