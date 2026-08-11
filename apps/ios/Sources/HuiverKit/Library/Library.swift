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

    public var isComplete: Bool { chunkCount > 0 && renderedChunks >= chunkCount }
    public var characters: Int { text.count }
}

public struct Book: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var author: String?
    public var added: Date
    public var chapters: [Chapter]

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
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([Book].self, from: data) {
            self.books = decoded
        } else {
            self.books = []
        }
    }

    public func all() -> [Book] { books.sorted { $0.added > $1.added } }

    public func book(_ id: String) -> Book? { books.first { $0.id == id } }

    public func add(_ extracted: ExtractedBook) throws -> Book {
        let bookId = UUID().uuidString
        let book = Book(
            id: bookId,
            title: extracted.title,
            author: extracted.author,
            added: Date(),
            chapters: extracted.chapters.enumerated().map { index, chapter in
                Chapter(
                    id: "\(bookId)-\(index)",
                    title: chapter.title,
                    text: chapter.text,
                    chunkCount: Chunker.chunkWithSentenceLead(chapter.text).count
                )
            }
        )
        books.append(book)
        try save()
        return book
    }

    public func remove(_ id: String) throws {
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

    /// Throw away a chapter's audio, which is what a change of voice means.
    public func discardAudio(chapterId: String, bookId: String) throws {
        try? FileManager.default.removeItem(at: audioDirectory(book: bookId, chapter: chapterId))
        guard var chapter = book(bookId)?.chapters.first(where: { $0.id == chapterId }) else { return }
        chapter.renderedChunks = 0
        chapter.renderedVoice = nil
        try update(chapter: chapter, in: bookId)
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(books).write(to: indexURL, options: .atomic)
    }
}
