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
    /// The asks this device has made, on the device that makes them. Absent on
    /// the Mac, which renders rather than asks.
    private let requests: ConvertRequestStore?
    /// Where an ask from the other device goes. Absent on the phone, which has
    /// nowhere to put one.
    ///
    /// A closure rather than a protocol because the thing on the far end is the
    /// Mac's `Converter`, which is `@MainActor` and knows about voices and
    /// engines — none of which belongs in a data source. It returns a status
    /// per request, which is what goes back over the wire.
    private let acceptRequests: (@Sendable ([ConvertRequest]) async -> [SyncMessage.JobStatus])?

    public init(
        library: Library,
        progress: ProgressStore,
        deviceId: String,
        voiceDirectory: URL? = nil,
        requests: ConvertRequestStore? = nil,
        acceptRequests: (@Sendable ([ConvertRequest]) async -> [SyncMessage.JobStatus])? = nil
    ) {
        self.library = library
        self.progress = progress
        self.deviceId = deviceId
        self.voiceDirectory = voiceDirectory
        self.requests = requests
        self.acceptRequests = acceptRequests
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
            progress: records,
            // Pruned against the library first: a chapter that has since been
            // rendered — here, or on the Mac in an earlier session — is not
            // something to keep asking for.
            convertRequests: await requests?.pending(against: books) ?? []
        )
    }

    public func acceptConvertRequests(
        _ requests: [ConvertRequest]
    ) async -> [SyncMessage.JobStatus] {
        guard let acceptRequests else { return [] }
        return await acceptRequests(requests)
    }

    public func receive(jobStatus: SyncMessage.JobStatus) async {
        await requests?.record(jobStatus)
    }

    /// The names the peer gave its voices, kept for the deliveries: a voice
    /// crosses as an id and a blob, and the manifest is the only place its
    /// name ever travels.
    private var peerVoiceNames: [String: String] = [:]

    public func receive(peerManifest: SyncMessage.Manifest) async {
        peerVoiceNames = Dictionary(
            peerManifest.voices.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
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
            // Into the manifest as well as onto disk: a blob the manifest does
            // not mention can never be loaded, and is asked for again by every
            // session that follows.
            try VoicePack.register(
                id: id,
                name: peerVoiceNames[id] ?? id,
                detail: "synced from another device",
                in: directory
            )

        case .voicePreview(let id):
            guard let directory = voiceDirectory else { return }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(
                to: directory.appendingPathComponent("\(id).preview.wav"), options: .atomic
            )
            // The preview may land before or after its voice; re-registering
            // once the voice file exists picks it up either way.
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(id).voice").path
            ) {
                try VoicePack.register(
                    id: id,
                    name: peerVoiceNames[id] ?? id,
                    detail: "synced from another device",
                    in: directory
                )
            }
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
