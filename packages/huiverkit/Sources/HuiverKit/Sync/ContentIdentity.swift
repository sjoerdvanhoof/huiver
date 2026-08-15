import CryptoKit
import Foundation

/// Stable identity for a book and its chapters, derived from the text itself.
///
/// The phone and the Mac import their own copies of the same EPUB and each
/// makes up a local `UUID` for it, so the two libraries have no id in common.
/// Sync needs one anyway: something both sides compute independently and agree
/// on. That is this.
///
/// It hashes the *extracted text*, not the EPUB file. Two reasons. The phone
/// throws the EPUB away after extracting it, so a file hash cannot identify the
/// books already in a library. And the same book genuinely arrives as different
/// bytes — a re-download, a different retailer, a repacked zip — while the text
/// inside is identical. Both apps run the same extractor, so the same book
/// reduces to the same text and therefore the same id.
///
/// The flip side: `Extract` and `Format` must stay deterministic. Any change to
/// how text comes out of an EPUB changes every id derived from it, and two
/// devices on different app versions would stop recognising the same book. When
/// that has to happen, bump `salt` so it is a clean break rather than a silent
/// mismatch.
public enum ContentIdentity {
    /// Bumped when the canonical text a book reduces to changes shape.
    /// v1: title, author, and the per-chapter text hashes.
    public static let salt = "huiver-book-v1"

    /// SHA-256 of a chapter's text, lowercase hex.
    ///
    /// The text goes in as-is rather than normalised: it is already the
    /// extractor's canonical output, and normalising here would be a second
    /// place for the two platforms to disagree.
    public static func chapterHash(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// The id both devices agree on for a book.
    ///
    /// Title and author are included so that two books whose text happens to
    /// match — a sample chapter, a boilerplate front matter file — do not merge
    /// on the strength of the text alone.
    public static func bookId(title: String, author: String?, chapterHashes: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(salt.utf8))
        for field in [title, author ?? ""] + chapterHashes {
            // Length-prefixed rather than delimiter-joined: a title containing
            // the delimiter would otherwise be able to impersonate a different
            // title/author split.
            var length = UInt32(field.utf8.count).littleEndian
            hasher.update(data: Data(bytes: &length, count: 4))
            hasher.update(data: Data(field.utf8))
        }
        return hex(hasher.finalize())
    }

    /// The id of a request to render one chapter in one voice.
    ///
    /// Derived from what is being asked for rather than randomly generated, so
    /// that asking twice is asking once. The phone re-sends its pending
    /// requests in every manifest — it has no way to know whether the last
    /// session's reached the Mac — and this is what stops that turning into a
    /// queue full of duplicates.
    public static func requestId(textHash: String, voiceId: String) -> String {
        hex(SHA256.hash(data: Data("\(textHash)\u{0}\(voiceId)".utf8)))
    }

    /// SHA-256 of a file's bytes, for verifying a transfer.
    public static func hash(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public extension Book {
    /// The chapter hashes this book's `contentId` is built from, computing any
    /// that a pre-identity library did not store.
    var chapterHashes: [String] {
        chapters.map { $0.textHash ?? ContentIdentity.chapterHash($0.text) }
    }

    /// What this book's `contentId` should be, whether or not one is stored.
    var derivedContentId: String {
        ContentIdentity.bookId(title: title, author: author, chapterHashes: chapterHashes)
    }
}
