import Foundation
import Testing

@testable import HuiverKit

/// Whether pressing play plays or synthesises.
///
/// This is one line of logic and it was wrong for months, because it was
/// written out at six call sites and every one of them asked about the voice.
/// A chapter rendered on the Mac arrives over sync carrying one of the Mac's
/// multilingual voice ids — a voice the phone filters out of its own roster,
/// since it cannot load those tensors — so "was this read by the voice I have
/// selected?" is permanently false for synced audio, and the answer sent the
/// listener into a re-render that deleted the transfer first.
struct PlaybackRouteTests {
    private func chapter(
        chunkCount: Int, rendered: Int, voice: String?
    ) -> Chapter {
        var chapter = Chapter(id: "book-0", title: "One", text: "Some prose.")
        chapter.chunkCount = chunkCount
        chapter.renderedChunks = rendered
        chapter.renderedVoice = voice
        return chapter
    }

    @Test("a chapter the Mac rendered plays, whatever voice read it")
    func syncedAudioReplays() {
        let synced = chapter(chunkCount: 12, rendered: 12, voice: "mtl_klett")
        #expect(Narrator.route(chapter: synced, chunksOnDisk: 12) == .replay)
    }

    @Test("a chapter this device rendered plays too")
    func ownAudioReplays() {
        let mine = chapter(chunkCount: 3, rendered: 3, voice: "nano_default")
        #expect(Narrator.route(chapter: mine, chunksOnDisk: 3) == .replay)
    }

    @Test("half a chapter is still rendered, not played")
    func partialAudioRenders() {
        let half = chapter(chunkCount: 12, rendered: 5, voice: "mtl_klett")
        #expect(Narrator.route(chapter: half, chunksOnDisk: 5) == .render)
    }

    /// The index is a record of what was written, not of what is still there:
    /// cleanup, a half-finished sync, a listener deleting audio in Files. The
    /// files decide, so the answer is never a spinner over an empty directory.
    @Test("an index that promises audio that has gone renders instead")
    func missingFilesRender() {
        let promised = chapter(chunkCount: 12, rendered: 12, voice: "mtl_klett")
        #expect(Narrator.route(chapter: promised, chunksOnDisk: 0) == .render)
        #expect(Narrator.route(chapter: promised, chunksOnDisk: 11) == .render)
    }

    @Test("a chapter nobody has rendered is rendered")
    func freshChapterRenders() {
        let fresh = chapter(chunkCount: 12, rendered: 0, voice: nil)
        #expect(Narrator.route(chapter: fresh, chunksOnDisk: 0) == .render)
        // An unchunked chapter is not complete however many files turn up.
        let unchunked = chapter(chunkCount: 0, rendered: 0, voice: nil)
        #expect(Narrator.route(chapter: unchunked, chunksOnDisk: 4) == .render)
    }
}
