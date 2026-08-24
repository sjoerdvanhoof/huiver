import Foundation

/// The library's `Chapter`, named so it can be reached from inside
/// `BookBundle`, whose own nested `Chapter` would otherwise shadow it.
///
/// Declared at file scope rather than qualified with the module name, because
/// there is no module to qualify with in the app targets: they compile these
/// sources directly, so `HuiverKit.Chapter` does not exist there.
private typealias LibraryChapter = Chapter

/// A book, packed for the wire.
///
/// The EPUB would be the obvious thing to send, and when the sending device
/// still has it, it is sent too. But it cannot be the only way a book travels:
/// every book imported before EPUBs were kept has no file behind it, and those
/// are exactly the books a first sync has to move. So this is the canonical
/// form — the extracted text, which is what both apps actually read from — and
/// the EPUB is an optional extra that arrives separately.
///
/// The receiving device does not re-extract. It takes these chapters verbatim,
/// which is what keeps the two libraries agreeing on `contentId`: re-extracting
/// on a different app version could produce subtly different text and therefore
/// a different id for a book that just arrived.
public struct BookBundle: Codable, Sendable, Equatable {
    public struct Chapter: Codable, Sendable, Equatable {
        public var index: Int
        public var title: String
        public var text: String
        public var textHash: String
        public var chunkCount: Int
        public var chunkerVersion: Int
        public var chunkingProfile: String?

        public init(
            index: Int,
            title: String,
            text: String,
            textHash: String,
            chunkCount: Int,
            chunkerVersion: Int,
            chunkingProfile: String? = nil
        ) {
            self.index = index
            self.title = title
            self.text = text
            self.textHash = textHash
            self.chunkCount = chunkCount
            self.chunkerVersion = chunkerVersion
            self.chunkingProfile = chunkingProfile
        }
    }

    public var contentId: String
    public var title: String
    public var author: String?
    public var language: String
    public var localeIdentifier: String?
    public var added: Date
    public var chapters: [Chapter]
    /// The cover, inline. A cover is tens of kilobytes and a book without one
    /// looks broken, so it is not worth a second round trip.
    public var cover: Data?
    public var coverExtension: String?

    public init(
        contentId: String,
        title: String,
        author: String?,
        language: String,
        localeIdentifier: String? = nil,
        added: Date,
        chapters: [Chapter],
        cover: Data? = nil,
        coverExtension: String? = nil
    ) {
        self.contentId = contentId
        self.title = title
        self.author = author
        self.language = language
        self.localeIdentifier = localeIdentifier
        self.added = added
        self.chapters = chapters
        self.cover = cover
        self.coverExtension = coverExtension
    }

    // MARK: - Making one

    /// Pack a book out of the local library.
    public static func make(from book: Book, coverURL: URL?) -> BookBundle {
        let cover = coverURL.flatMap { try? Data(contentsOf: $0) }
        return BookBundle(
            contentId: book.contentId ?? book.derivedContentId,
            title: book.title,
            author: book.author,
            language: book.languageCode,
            localeIdentifier: book.localeIdentifier,
            added: book.added,
            chapters: book.chapters.enumerated().map { index, chapter in
                Chapter(
                    index: index,
                    title: chapter.title,
                    text: chapter.text,
                    textHash: chapter.textHash ?? ContentIdentity.chapterHash(chapter.text),
                    chunkCount: chapter.chunkCount,
                    chunkerVersion: chapter.chunkerVersion ?? Chunker.version,
                    chunkingProfile: chapter.chunkingProfile
                )
            },
            cover: cover,
            coverExtension: coverURL?.pathExtension
        )
    }

    /// What the sender's manifest says about this book.
    public static func manifest(for book: Book, coverURL: URL?, epubURL: URL?) -> BookManifest {
        BookManifest(
            contentId: book.contentId ?? book.derivedContentId,
            title: book.title,
            author: book.author,
            language: book.languageCode,
            localeIdentifier: book.localeIdentifier,
            hasCover: coverURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            hasEpub: epubURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            chapters: book.chapters.enumerated().map { index, chapter in
                ChapterManifest(
                    index: index,
                    title: chapter.title,
                    textHash: chapter.textHash ?? ContentIdentity.chapterHash(chapter.text),
                    chunkCount: chapter.chunkCount,
                    chunkerVersion: chapter.chunkerVersion ?? Chunker.version,
                    chunkingProfile: chapter.chunkingProfile,
                    audio: chapter.renderedChunks > 0
                        ? AudioManifest(
                            voiceId: chapter.renderedVoice ?? "",
                            renderedChunks: chapter.renderedChunks,
                            codec: .wav
                        )
                        : nil
                )
            }
        )
    }

    // MARK: - Unpacking one

    /// The book this bundle describes, ready to be written into a library.
    ///
    /// The local id is minted here rather than taken from the sender: it names
    /// this device's own audio directories, and two devices are entitled to
    /// disagree about it. `contentId` is what they agree on.
    public func book(localId: String = UUID().uuidString, coverFile: String?) -> Book {
        var book = Book(
            id: localId,
            title: title,
            author: author,
            added: added,
            language: language,
            localeIdentifier: localeIdentifier,
            coverFile: coverFile,
            chapters: chapters.sorted { $0.index < $1.index }.map { chapter in
                LibraryChapter(
                    id: "\(localId)-\(chapter.index)",
                    title: chapter.title,
                    text: chapter.text,
                    chunkCount: chapter.chunkCount,
                    textHash: chapter.textHash,
                    chunkerVersion: chapter.chunkerVersion,
                    chunkingProfile: chapter.chunkingProfile
                )
            }
        )
        book.contentId = contentId
        return book
    }

    /// Does this bundle say what it is? A `contentId` that does not match the
    /// text it arrived with means one of the two devices computed it
    /// differently, and taking the book anyway would put a book in the library
    /// that neither device can find again.
    public var isSelfConsistent: Bool {
        let recomputed = ContentIdentity.bookId(
            title: title,
            author: author,
            chapterHashes: chapters.sorted { $0.index < $1.index }.map(\.textHash)
        )
        let textMatches = chapters.allSatisfy {
            ContentIdentity.chapterHash($0.text) == $0.textHash
        }
        return recomputed == contentId && textMatches
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> BookBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookBundle.self, from: data)
    }
}
