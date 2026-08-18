import Foundation
import Testing

@testable import HuiverKit

/// Cross-device book identity.
///
/// The one property everything in sync rests on: two devices that imported the
/// same EPUB independently must arrive at the same `contentId`, and two
/// different books must not. Everything else — which chapters to send, which
/// audio is already there — is keyed off it.
struct IdentityTests {
    func makeExtracted(
        title: String = "The Quiet Harbour",
        author: String? = "A. Writer",
        chapters: [(String, String)] = [("One", "The town woke slowly."), ("Two", "Then it rained.")]
    ) -> ExtractedBook {
        ExtractedBook(
            title: title,
            author: author,
            chapters: chapters.map { ExtractedChapter(title: $0.0, text: $0.1) }
        )
    }

    /// The same book imported twice — on two devices, with two local UUIDs —
    /// is the same book.
    @Test("the same text gives the same id in two separate libraries")
    func stableAcrossLibraries() async throws {
        let extracted = makeExtracted()
        let phone = try Library(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let mac = try Library(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        let onPhone = try await phone.add(extracted, language: .english)
        let onMac = try await mac.add(extracted, language: .english)

        #expect(onPhone.id != onMac.id, "local ids are per-device")
        #expect(onPhone.contentId != nil)
        #expect(onPhone.contentId == onMac.contentId, "content ids are not")
    }

    @Test("a different chapter text gives a different id")
    func textChangesIdentity() {
        let a = makeExtracted()
        let b = makeExtracted(chapters: [("One", "The town woke slowly."), ("Two", "Then it snowed.")])
        #expect(identity(of: a) != identity(of: b))
    }

    @Test("title and author are part of the identity")
    func metadataChangesIdentity() {
        let base = makeExtracted()
        #expect(identity(of: base) != identity(of: makeExtracted(title: "A Loud Harbour")))
        #expect(identity(of: base) != identity(of: makeExtracted(author: "B. Writer")))
    }

    /// Fields are length-prefixed rather than joined with a separator, so a
    /// title cannot be crafted to look like a different title/author split.
    @Test("moving text between title and author changes the id")
    func fieldsCannotBeSmuggled() {
        let a = ContentIdentity.bookId(title: "Harbour", author: "Writer", chapterHashes: ["x"])
        let b = ContentIdentity.bookId(title: "HarbourWriter", author: "", chapterHashes: ["x"])
        #expect(a != b)
    }

    @Test("chapter hashes are stamped on import")
    func stampsChapterHashes() async throws {
        let library = try Library(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let book = try await library.add(makeExtracted(), language: .english)
        for chapter in book.chapters {
            #expect(chapter.textHash == ContentIdentity.chapterHash(chapter.text))
            #expect(chapter.chunkerVersion == Chunker.version)
        }
    }

    /// A library.json written before sync existed has no hashes at all. Opening
    /// it must fill them in and persist, or the first sync would compare
    /// against nothing.
    @Test("a pre-identity library is migrated on open")
    func migratesOldLibraries() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Exactly the shape the old encoder produced: no textHash, no
        // chunkerVersion, no contentId, no epubFile.
        let old = """
        [{
          "id": "local-uuid",
          "title": "The Quiet Harbour",
          "author": "A. Writer",
          "added": 750000000,
          "language": "en",
          "chapters": [
            { "id": "local-uuid-0", "title": "One", "text": "The town woke slowly.",
              "chunkCount": 1, "renderedChunks": 0 }
          ]
        }]
        """
        try Data(old.utf8).write(to: root.appendingPathComponent("library.json"))

        let library = try Library(root: root)
        let book = try #require(await library.book("local-uuid"))
        #expect(book.contentId != nil)
        #expect(book.chapters[0].textHash == ContentIdentity.chapterHash("The town woke slowly."))

        // And it stuck: a second open reads the migrated file rather than
        // recomputing from scratch.
        let reopened = try Library(root: root)
        let again = try #require(await reopened.book("local-uuid"))
        #expect(again.contentId == book.contentId)
    }

    /// The same book, migrated from an old library on one device and imported
    /// fresh on another, still meets in the middle.
    @Test("a migrated book matches a freshly imported one")
    func migrationMatchesImport() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = """
        [{
          "id": "local-uuid", "title": "The Quiet Harbour", "author": "A. Writer",
          "added": 750000000, "language": "en",
          "chapters": [
            { "id": "local-uuid-0", "title": "One", "text": "The town woke slowly.",
              "chunkCount": 1, "renderedChunks": 0 },
            { "id": "local-uuid-1", "title": "Two", "text": "Then it rained.",
              "chunkCount": 1, "renderedChunks": 0 }
          ]
        }]
        """
        try Data(old.utf8).write(to: root.appendingPathComponent("library.json"))

        let migrated = try #require(await Library(root: root).book("local-uuid"))
        let fresh = try await Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ).add(makeExtracted(), language: .english)

        #expect(migrated.contentId == fresh.contentId)
    }

    @Test("the imported EPUB is kept when it is handed over")
    func retainsSourceFile() async throws {
        let library = try Library(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let bytes = Data("not really an epub, but it is what was imported".utf8)
        let book = try await library.add(
            makeExtracted(), language: .english, source: (data: bytes, filename: "harbour.epub")
        )
        let url = try #require(library.epubURL(book))
        #expect(try Data(contentsOf: url) == bytes)

        // And it goes away with the book, rather than leaking a few MB per
        // deleted title.
        try await library.remove(book.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a book imported without its file simply has none")
    func sourceIsOptional() async throws {
        let library = try Library(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let book = try await library.add(makeExtracted(), language: .english)
        #expect(book.epubFile == nil)
        #expect(library.epubURL(book) == nil)
    }

    private func identity(of extracted: ExtractedBook) -> String {
        ContentIdentity.bookId(
            title: extracted.title,
            author: extracted.author,
            chapterHashes: extracted.chapters.map { ContentIdentity.chapterHash($0.text) }
        )
    }
}
