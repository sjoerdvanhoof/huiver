import Foundation

/// `SyncDataSource` over the real library and progress store.
///
/// This is where wire identities meet local ones: the manifest speaks
/// `contentId` and chapter *indexes*, the disk speaks local UUIDs and chapter
/// ids. The mapping is looked up fresh from the library on every call rather
/// than cached, because sync sessions are rare and stale mappings are how a
/// book ends up written over the wrong one.
public actor LibrarySyncDataSource: SyncDataSource {
    private let library: Library
    private let progress: ProgressStore
    private let deviceId: String
    /// Voices available to offer, with their file locations. Bundled voices on
    /// the phone; the voice directory on the Mac.
    private let voiceDirectory: URL?

    public init(
        library: Library,
        progress: ProgressStore,
        deviceId: String,
        voiceDirectory: URL? = nil
    ) {
        self.library = library
        self.progress = progress
        self.deviceId = deviceId
        self.voiceDirectory = voiceDirectory
    }

    // MARK: - Manifest

    public func manifest() async -> SyncMessage.Manifest {
        let books = await library.all()
        let positions = await progress.chapters()

        var records: [ProgressRecord] = []
        for book in books {
            guard let contentId = book.contentId else { continue }
            for (index, chapter) in book.chapters.enumerated() {
                guard let record = positions[chapter.id] else { continue }
                records.append(
                    ProgressRecord(
                        contentId: contentId,
                        chapterIndex: index,
                        position: record.position,
                        finished: record.finished,
                        updatedAt: record.updatedAt,
                        deviceId: deviceId
                    )
                )
            }
        }

        return SyncMessage.Manifest(
            books: books.map {
                BookBundle.manifest(
                    for: $0, coverURL: library.coverURL($0), epubURL: library.epubURL($0)
                )
            },
            voices: voiceManifests(),
            progress: records
        )
    }

    private func voiceManifests() -> [VoiceManifest] {
        guard let directory = voiceDirectory,
              let voices = try? VoicePack.load(from: directory)
        else { return [] }
        return voices.map {
            VoiceManifest(id: $0.id, name: $0.name, hasPreview: $0.previewURL != nil)
        }
    }

    // MARK: - Serving

    public func data(for item: WantItem) async throws -> Data? {
        switch item {
        case .bookBundle(let contentId):
            guard let book = await book(contentId) else { return nil }
            return try BookBundle.make(from: book, coverURL: library.coverURL(book)).encoded()

        case .epub(let contentId):
            guard let book = await book(contentId), let url = library.epubURL(book) else {
                return nil
            }
            return try? Data(contentsOf: url)

        case .audio(let contentId, let chapterIndex, let voiceId, let chunks):
            guard let book = await book(contentId),
                  book.chapters.indices.contains(chapterIndex)
            else { return nil }
            let chapter = book.chapters[chapterIndex]
            guard chapter.renderedVoice == voiceId else { return nil }
            return ChunkPack.pack(
                chunks.compactMap { index in
                    let url = library.chunkURL(book: book.id, chapter: chapter.id, index: index)
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return (index, data)
                }
            )

        case .voice(let id):
            guard let directory = voiceDirectory else { return nil }
            return try? Data(contentsOf: directory.appendingPathComponent("\(id).voice"))

        case .voicePreview(let id):
            guard let directory = voiceDirectory else { return nil }
            return try? Data(contentsOf: directory.appendingPathComponent("\(id).preview.wav"))
        }
    }

    // MARK: - Receiving

    public func receive(_ item: WantItem, data: Data) async throws {
        switch item {
        case .bookBundle:
            let bundle = try BookBundle.decode(data)
            // A bundle that misdescribes itself would be invisible to the next
            // diff — both sides would offer it to each other forever.
            guard bundle.isSelfConsistent else {
                throw SyncSession.SyncError.corruptTransfer("book \(bundle.title)")
            }
            guard await book(bundle.contentId) == nil else { return }
            try await library.insert(bundle)

        case .epub(let contentId):
            guard let book = await book(contentId) else { return }
            try await library.attachEpub(data, to: book.id)

        case .audio(let contentId, let chapterIndex, let voiceId, _):
            guard let book = await book(contentId),
                  book.chapters.indices.contains(chapterIndex)
            else { return }
            let chapter = book.chapters[chapterIndex]
            // Local audio in a different voice wins; the diff should not have
            // asked, but the diff ran against a manifest that may have aged.
            if let existing = chapter.renderedVoice, existing != voiceId,
               chapter.renderedChunks > 0 {
                return
            }
            try await library.storeChunks(
                ChunkPack.unpack(data), bookId: book.id, chapterId: chapter.id, voiceId: voiceId
            )

        case .voice(let id):
            guard let directory = voiceDirectory else { return }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: directory.appendingPathComponent("\(id).voice"), options: .atomic)

        case .voicePreview(let id):
            guard let directory = voiceDirectory else { return }
            try data.write(
                to: directory.appendingPathComponent("\(id).preview.wav"), options: .atomic
            )
        }
    }

    public func mergeProgress(_ records: [ProgressRecord]) async {
        let books = await library.all()
        for record in records {
            guard let book = books.first(where: { $0.contentId == record.contentId }),
                  book.chapters.indices.contains(record.chapterIndex)
            else { continue }
            await progress.merge(
                record.chapterProgress,
                chapterId: book.chapters[record.chapterIndex].id,
                bookId: book.id
            )
        }
        await progress.flush()
    }

    private func book(_ contentId: String) async -> Book? {
        await library.all().first { $0.contentId == contentId }
    }
}

/// Several chunk files in one blob: `u32 count | (u32 index | u32 length |
/// bytes)*`. Little-endian, like the framing.
///
/// One blob per requested range rather than one transfer per chunk, because a
/// chapter is a couple of hundred chunks and each transfer costs a header, a
/// hash and two control frames.
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
