import Foundation
import Testing

@testable import HuiverKit

/// The phone's side of convert-offload: what it remembers having asked for.
struct ConvertRequestTests {
    func store() -> (ConvertRequestStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ConvertRequestStore(root: root), root)
    }

    func book(
        contentId: String = "book",
        chapters: Int = 2,
        renderedChunks: Int = 0,
        voice: String? = nil
    ) -> Book {
        Book(
            id: "local",
            title: "A Book",
            added: Date(),
            chapters: (0..<chapters).map { index in
                Chapter(
                    id: "chapter-\(index)",
                    title: "Chapter \(index + 1)",
                    text: "text \(index)",
                    renderedVoice: voice,
                    chunkCount: 10,
                    renderedChunks: renderedChunks,
                    textHash: "hash-\(index)"
                )
            },
            contentId: contentId
        )
    }

    @Test("asking twice is asking once")
    func idempotent() async {
        let (store, _) = store()
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        #expect(await store.all().count == 1)
    }

    @Test("the same chapter in a second voice is a second ask")
    func voiceIsPartOfIdentity() async {
        let (store, _) = store()
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "nano")
        #expect(await store.all().count == 2)
    }

    @Test("an ask survives the app being restarted")
    func persists() async {
        let (store, root) = store()
        await store.add(contentId: "book", chapterIndex: 1, textHash: "hash-1", voiceId: "ruth")
        let reopened = ConvertRequestStore(root: root)
        #expect(await reopened.all().count == 1)
        #expect(await reopened.all().first?.chapterIndex == 1)
    }

    @Test("a chapter that has since been rendered is no longer asked for")
    func prunesRendered() async {
        let (store, _) = store()
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        let done = book(renderedChunks: 10, voice: "ruth")
        #expect(await store.pending(against: [done]).isEmpty)
        #expect(await store.all().isEmpty, "the pruning is remembered, not recomputed each time")
    }

    /// Rendered, but by a different narrator than the one that was asked for.
    /// The ask stands: the audio on disk is not what was wanted.
    @Test("a chapter rendered in another voice is still asked for")
    func keepsWhenVoiceDiffers() async {
        let (store, _) = store()
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        #expect(await store.pending(against: [book(renderedChunks: 10, voice: "nano")]).count == 1)
    }

    @Test("a half-rendered chapter is still asked for")
    func keepsWhenIncomplete() async {
        let (store, _) = store()
        await store.add(contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        #expect(await store.pending(against: [book(renderedChunks: 4, voice: "ruth")]).count == 1)
    }

    @Test("an ask for a book that has been deleted goes with it")
    func prunesDeletedBook() async {
        let (store, _) = store()
        await store.add(contentId: "gone", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth")
        #expect(await store.pending(against: [book()]).isEmpty)
    }

    @Test("what the Mac said is kept against the ask")
    func recordsStatus() async {
        let (store, _) = store()
        let request = await store.add(
            contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth"
        )
        await store.record(
            SyncMessage.JobStatus(
                requestId: request.requestId, state: .rendering, renderedChunks: 3, chunkCount: 10
            )
        )
        let state = await store.state(textHash: "hash-0", voiceId: "ruth")
        #expect(state?.status?.state == .rendering)
        #expect(state?.status?.renderedChunks == 3)
    }

    /// A Mac paired with two phones answers both. A status for the other
    /// phone's ask is not this phone's business.
    @Test("a status for an ask this device never made is dropped")
    func ignoresUnknownStatus() async {
        let (store, _) = store()
        await store.record(
            SyncMessage.JobStatus(
                requestId: "someone-else", state: .done, renderedChunks: 10, chunkCount: 10
            )
        )
        #expect(await store.status(requestId: "someone-else") == nil)
    }

    @Test("cancelling an ask takes its status with it")
    func removeClearsStatus() async {
        let (store, _) = store()
        let request = await store.add(
            contentId: "book", chapterIndex: 0, textHash: "hash-0", voiceId: "ruth"
        )
        await store.record(
            SyncMessage.JobStatus(
                requestId: request.requestId, state: .queued, renderedChunks: 0, chunkCount: 10
            )
        )
        await store.remove(textHash: "hash-0", voiceId: "ruth")
        #expect(await store.all().isEmpty)
        #expect(await store.status(requestId: request.requestId) == nil)
    }
}
