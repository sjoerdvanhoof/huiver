import Foundation

public struct Chapter: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var text: String
    /// Which voice the stored audio was rendered in, so switching voice
    /// invalidates it rather than producing a chapter read by two narrators.
    public var renderedVoice: String?
    public var chunkCount: Int = 0
    public var renderedChunks: Int = 0
    /// SHA-256 of `text`, the half of this chapter's cross-device identity that
    /// is not the book. Optional so a library written before sync existed still
    /// decodes; `Library` fills it in on load.
    public var textHash: String?
    /// Which chunker produced `chunkCount`. Audio is only interchangeable
    /// between devices that agree on where the chunk boundaries are.
    public var chunkerVersion: Int?
    /// Why the last attempt to render this chapter stopped, if it stopped
    /// badly. The only part of conversion state worth storing: everything else
    /// — queued, converting, converted — is derivable from the queue and the
    /// files on disk, and a stored copy of a derivable thing only drifts.
    public var lastRenderError: String?

    public var isComplete: Bool { chunkCount > 0 && renderedChunks >= chunkCount }
    public var characters: Int { text.count }
}

public struct Book: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var author: String?
    public var added: Date
    /// Optional so that a library written before languages existed still
    /// decodes; absent means English, which is what those books were read as.
    public var language: String?
    /// File name of the cover inside `covers/`, if the book had one. A name
    /// rather than a path, so moving the library does not break it.
    public var coverFile: String?
    public var chapters: [Chapter]
    /// The id this book has on every device that imported it, from
    /// `ContentIdentity`. `id` stays the local key — it names the audio folders
    /// — and this is what goes over the wire. Optional for libraries written
    /// before sync; `Library` fills it in on load.
    public var contentId: String?
    /// File name of the original EPUB inside `epubs/`, when it was kept.
    /// Absent for books imported before that started, and for books that
    /// arrived over sync as text rather than as a file.
    public var epubFile: String?

    public var languageCode: String { language ?? Language.english.code }

    public var characters: Int { chapters.reduce(0) { $0 + $1.characters } }
}

/// The library, as files in the app's Documents directory.
///
/// A JSON index and a folder of WAVs per chapter, rather than SQLite. The
/// desktop app needs a database because it has a job queue, resumable
/// conversions and concurrent readers; the phone renders one chapter at a time
/// for one person, and the rendered chunks on disk already are the state. What
/// is left to store is small enough to rewrite whole.
public actor Library {
    public let root: URL
    private let indexURL: URL
    private var books: [Book]

    public init(root: URL) throws {
        self.root = root
        self.indexURL = root.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var loaded: [Book]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        // Books imported before sync existed have no content identity. Compute
        // it once here rather than lazily at every comparison: hashing a whole
        // library is milliseconds, and a half-identified library is a source of
        // bugs that only show up when two devices meet.
        if let migrated = Self.stampIdentity(loaded) {
            loaded = migrated
            try? Self.write(loaded, to: indexURL)
        }
        self.books = loaded
    }

    /// Fill in `textHash`, `chunkerVersion` and `contentId` wherever they are
    /// missing, or return nil when there was nothing to fill in.
    ///
    /// Only ever adds. An existing hash is left alone even if the text no
    /// longer matches it — that would mean the text was edited underneath us,
    /// which nothing does, and recomputing would silently change the book's
    /// identity on one device only.
    static func stampIdentity(_ books: [Book]) -> [Book]? {
        var books = books
        var changed = false
        for bookIndex in books.indices {
            for chapterIndex in books[bookIndex].chapters.indices {
                if books[bookIndex].chapters[chapterIndex].textHash == nil {
                    let text = books[bookIndex].chapters[chapterIndex].text
                    books[bookIndex].chapters[chapterIndex].textHash =
                        ContentIdentity.chapterHash(text)
                    changed = true
                }
                // Re-chunk a chapter the chunker has moved on from — but only
                // when there is no audio to contradict. A chapter already
                // rendered keeps the boundaries its files were made with, and
                // its `chunks.json` says what they were; re-chunking it here
                // would leave `chunkCount` describing audio that does not
                // exist. `ChapterRenderer` discards the old audio if it is ever
                // asked to extend it.
                if books[bookIndex].chapters[chapterIndex].chunkerVersion != Chunker.version,
                   books[bookIndex].chapters[chapterIndex].renderedChunks == 0 {
                    let text = books[bookIndex].chapters[chapterIndex].text
                    books[bookIndex].chapters[chapterIndex].chunkCount =
                        Chunker.chunkWithSentenceLead(text).count
                    books[bookIndex].chapters[chapterIndex].chunkerVersion = Chunker.version
                    changed = true
                }
            }
            if books[bookIndex].contentId == nil {
                books[bookIndex].contentId = books[bookIndex].derivedContentId
                changed = true
            }
        }
        return changed ? books : nil
    }

    public func all() -> [Book] { books.sorted { $0.added > $1.added } }

    public func book(_ id: String) -> Book? { books.first { $0.id == id } }

    /// Add a book.
    ///
    /// `source` is the file it was extracted from. Keeping it costs a few MB
    /// per book and buys two things: re-extracting when the extractor improves,
    /// and handing the real EPUB to the other device at sync time rather than a
    /// text-only reduction of it.
    public func add(
        _ extracted: ExtractedBook,
        language: Language? = nil,
        source: (data: Data, filename: String)? = nil
    ) throws -> Book {
        let bookId = UUID().uuidString
        // Guessed from the book's own text at import, and overridable per book.
        let detected = language ?? Language.detect(
            in: extracted.chapters.prefix(3).map(\.text).joined(separator: " ")
        )

        var cover: String?
        if let image = extracted.cover {
            let name = "\(bookId).\(image.extension)"
            let directory = root.appendingPathComponent("covers")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A missing cover is a cosmetic problem, not a reason to refuse the
            // book, so a failed write leaves it on the gradient placeholder.
            if (try? image.data.write(to: directory.appendingPathComponent(name))) != nil {
                cover = name
            }
        }
        // Same posture as the cover: keeping the EPUB is a convenience, so a
        // failed write costs the book nothing.
        var epub: String?
        if let source {
            let given = URL(fileURLWithPath: source.filename).pathExtension
            let name = "\(bookId).\(given.isEmpty ? "epub" : given)"
            let directory = root.appendingPathComponent("epubs")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? source.data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil {
                epub = name
            }
        }

        let chapters = extracted.chapters.enumerated().map { index, chapter in
            Chapter(
                id: "\(bookId)-\(index)",
                title: chapter.title,
                text: chapter.text,
                chunkCount: Chunker.chunkWithSentenceLead(chapter.text).count,
                textHash: ContentIdentity.chapterHash(chapter.text),
                chunkerVersion: Chunker.version
            )
        }
        var book = Book(
            id: bookId,
            title: extracted.title,
            author: extracted.author,
            added: Date(),
            language: detected.code,
            coverFile: cover,
            chapters: chapters,
            epubFile: epub
        )
        book.contentId = book.derivedContentId
        books.append(book)
        try save()
        return book
    }

    /// Change a book's language. Does not touch its audio: what language the
    /// text is in does not change what has already been spoken, and re-reading
    /// it is the user's call.
    public func setLanguage(_ language: Language, for bookId: String) throws {
        guard let index = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[index].language = language.code
        try save()
    }

    public func remove(_ id: String) throws {
        if let book = books.first(where: { $0.id == id }) {
            if let cover = coverURL(book) { try? FileManager.default.removeItem(at: cover) }
            if let epub = epubURL(book) { try? FileManager.default.removeItem(at: epub) }
        }
        books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: audioDirectory(book: id))
        try save()
    }

    public func update(chapter: Chapter, in bookId: String) throws {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookId }),
              let chapterIndex = books[bookIndex].chapters.firstIndex(where: { $0.id == chapter.id })
        else { return }
        books[bookIndex].chapters[chapterIndex] = chapter
        try save()
    }

    /// Record — or clear — why a chapter last failed to render.
    public func setRenderError(_ message: String?, chapterId: String, bookId: String) throws {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookId }),
              let chapterIndex = books[bookIndex].chapters.firstIndex(where: { $0.id == chapterId })
        else { return }
        guard books[bookIndex].chapters[chapterIndex].lastRenderError != message else { return }
        books[bookIndex].chapters[chapterIndex].lastRenderError = message
        try save()
    }

    /// Throw away a chapter's audio, which is what a change of voice means.
    public func discardAudio(chapterId: String, bookId: String) throws {
        try? FileManager.default.removeItem(at: audioDirectory(book: bookId, chapter: chapterId))
        guard var chapter = book(bookId)?.chapters.first(where: { $0.id == chapterId }) else { return }
        chapter.renderedChunks = 0
        chapter.renderedVoice = nil
        try update(chapter: chapter, in: bookId)
    }

    /// Where a book's cover image is, if it has one.
    public nonisolated func coverURL(_ book: Book) -> URL? {
        guard let file = book.coverFile else { return nil }
        return root.appendingPathComponent("covers").appendingPathComponent(file)
    }

    /// Where a book's original EPUB is, if it was kept.
    public nonisolated func epubURL(_ book: Book) -> URL? {
        guard let file = book.epubFile else { return nil }
        return root.appendingPathComponent("epubs").appendingPathComponent(file)
    }

    public nonisolated func audioDirectory(book: String, chapter: String? = nil) -> URL {
        var url = root.appendingPathComponent("audio").appendingPathComponent(book)
        if let chapter { url = url.appendingPathComponent(chapter) }
        return url
    }

    /// Rendered chunks are named by index so they sort and can be found without
    /// an index; the count on disk is the resume point.
    public nonisolated func chunkURL(book: String, chapter: String, index: Int) -> URL {
        audioDirectory(book: book, chapter: chapter)
            .appendingPathComponent(String(format: "%05d.wav", index))
    }

    public func bytesOnDisk() -> Int64 {
        let audio = root.appendingPathComponent("audio")
        guard let walker = FileManager.default.enumerator(
            at: audio, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return walker.reduce(Int64(0)) { total, item in
            guard let url = item as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return total }
            return total + Int64(size)
        }
    }

    private func save() throws {
        try Self.write(books, to: indexURL)
    }

    static func write(_ books: [Book], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(books).write(to: url, options: .atomic)
    }
}
