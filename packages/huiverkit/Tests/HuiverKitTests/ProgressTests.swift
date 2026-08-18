import Foundation
import Testing

@testable import HuiverKit

/// The listening position, which the phone had none of before.
///
/// The property that matters is that it survives: the app is normally killed
/// while suspended rather than closed, so anything only held in memory is lost
/// exactly when it is needed.
struct ProgressTests {
    func makeStore() -> (ProgressStore, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProgressStore(root: root), root)
    }

    @Test("a position survives a relaunch")
    func persists() async throws {
        let (store, root) = makeStore()
        await store.setPosition(812.5, chapterId: "book-3", bookId: "book")
        await store.flush()

        let reopened = ProgressStore(root: root)
        let record = try #require(await reopened.chapter("book-3"))
        #expect(record.position == 812.5)
        #expect(record.finished == false)
    }

    /// Positions arrive four times a second. They must not reach the disk that
    /// often — the flush is on a timer, and until it fires the file holds
    /// whatever was last written.
    @Test("ticks stay in memory until flushed")
    func debounces() async throws {
        let (store, root) = makeStore()
        await store.setPosition(10, chapterId: "book-0", bookId: "book")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("progress.json").path))

        // In memory immediately, though.
        #expect(await store.chapter("book-0")?.position == 10)

        await store.flush()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("progress.json").path))
    }

    @Test("finishing a chapter is remembered")
    func finishing() async throws {
        let (store, root) = makeStore()
        await store.setFinished(true, chapterId: "book-1", bookId: "book")
        await store.flush()

        let reopened = ProgressStore(root: root)
        #expect(await reopened.chapter("book-1")?.finished == true)
    }

    /// The cleanup sweep deletes a finished chapter's audio. The record of it
    /// having been finished has to outlive the audio, or the chapter would look
    /// unheard the moment its files went away.
    @Test("finished outlives the audio it describes")
    func finishedIsIndependentOfAudio() async throws {
        let (store, _) = makeStore()
        await store.setPosition(600, chapterId: "book-2", bookId: "book")
        await store.setFinished(true, chapterId: "book-2", bookId: "book")
        let record = try #require(await store.chapter("book-2"))
        #expect(record.finished)
        #expect(record.position == 600)
    }

    @Test("the book points at the chapter last listened to")
    func tracksLastChapter() async throws {
        let (store, _) = makeStore()
        await store.setPosition(30, chapterId: "book-0", bookId: "book")
        await store.setPosition(45, chapterId: "book-1", bookId: "book")
        #expect(await store.book("book")?.lastChapterId == "book-1")
    }

    @Test("deleting a book forgets its progress")
    func removesBook() async throws {
        let (store, _) = makeStore()
        await store.setPosition(30, chapterId: "book-0", bookId: "book")
        await store.setPosition(30, chapterId: "other-0", bookId: "other")
        await store.removeBook("book", chapterIds: ["book-0"])

        #expect(await store.chapter("book-0") == nil)
        #expect(await store.book("book") == nil)
        #expect(await store.chapter("other-0") != nil, "someone else's book is untouched")
    }

    // MARK: - Merging, which is what sync will do with these

    @Test("a newer record from the other device wins")
    func mergeNewer() async throws {
        let (store, _) = makeStore()
        let old = Date(timeIntervalSinceReferenceDate: 1000)
        await store.merge(
            ChapterProgress(position: 100, finished: false, updatedAt: old),
            chapterId: "book-0", bookId: "book"
        )
        let taken = await store.merge(
            ChapterProgress(position: 400, finished: false, updatedAt: old.addingTimeInterval(60)),
            chapterId: "book-0", bookId: "book"
        )
        #expect(taken)
        #expect(await store.chapter("book-0")?.position == 400)
    }

    @Test("an older record from the other device is ignored")
    func mergeOlder() async throws {
        let (store, _) = makeStore()
        let now = Date(timeIntervalSinceReferenceDate: 2000)
        await store.merge(
            ChapterProgress(position: 400, finished: false, updatedAt: now),
            chapterId: "book-0", bookId: "book"
        )
        let taken = await store.merge(
            ChapterProgress(position: 100, finished: false, updatedAt: now.addingTimeInterval(-60)),
            chapterId: "book-0", bookId: "book"
        )
        #expect(!taken)
        #expect(await store.chapter("book-0")?.position == 400, "the local position stands")
    }

    /// Two devices, same second. Whoever is compared second must not win by
    /// accident: equal timestamps keep what is already here, so the merge is
    /// stable however many times it runs.
    @Test("an equally old record does not overwrite")
    func mergeTie() async throws {
        let (store, _) = makeStore()
        let stamp = Date(timeIntervalSinceReferenceDate: 3000)
        await store.merge(
            ChapterProgress(position: 400, finished: false, updatedAt: stamp),
            chapterId: "book-0", bookId: "book"
        )
        let taken = await store.merge(
            ChapterProgress(position: 100, finished: true, updatedAt: stamp),
            chapterId: "book-0", bookId: "book"
        )
        #expect(!taken)
        #expect(await store.chapter("book-0")?.position == 400)
    }

    @Test("a merge of an unknown chapter is simply taken")
    func mergeUnknown() async throws {
        let (store, _) = makeStore()
        let taken = await store.merge(
            ChapterProgress(position: 55, finished: false, updatedAt: Date()),
            chapterId: "book-9", bookId: "book"
        )
        #expect(taken)
        #expect(await store.chapter("book-9")?.position == 55)
    }

    /// A progress file written by a future version, or half-written by a crash,
    /// must not stop the app opening.
    @Test("an unreadable file starts empty rather than throwing")
    func toleratesCorruption() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8)
            .write(to: root.appendingPathComponent("progress.json"))

        let store = ProgressStore(root: root)
        #expect(await store.chapters().isEmpty)

        // And it recovers: the next write replaces the rubbish.
        await store.setPosition(12, chapterId: "book-0", bookId: "book")
        await store.flush()
        #expect(await ProgressStore(root: root).chapter("book-0")?.position == 12)
    }
}
