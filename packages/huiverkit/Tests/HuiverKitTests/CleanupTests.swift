import Foundation
import Testing

@testable import HuiverKit

/// Which finished chapters may have their audio deleted.
///
/// Tested against an injected clock rather than by waiting a week, and against
/// the two ways this feature could go wrong in a way you would only notice
/// while listening: deleting what is playing, and deleting a prefix the
/// renderer is about to extend.
struct CleanupTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func makeBook(chapters: Int = 3, rendered: Bool = true) -> Book {
        var book = Book(
            id: "book",
            title: "A Book",
            author: nil,
            added: now,
            language: "en",
            coverFile: nil,
            chapters: (0..<chapters).map { index in
                Chapter(
                    id: "book-\(index)",
                    title: "Chapter \(index + 1)",
                    text: "Words.",
                    renderedVoice: rendered ? "ruth" : nil,
                    chunkCount: 10,
                    renderedChunks: rendered ? 10 : 0
                )
            }
        )
        book.contentId = "content"
        return book
    }

    func finished(_ daysAgo: Double) -> ChapterProgress {
        ChapterProgress(
            position: 600, finished: true,
            updatedAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
        )
    }

    @Test("a chapter finished long ago is eligible")
    func sweepsOldFinishedChapters() {
        let book = makeBook(chapters: 1)
        let eligible = AudioCleaner.eligible(
            books: [book], progress: ["book-0": finished(10)], now: now
        )
        #expect(eligible.map(\.chapterId) == ["book-0"])
    }

    /// The grace period is for the listener who fell asleep and wants the last
    /// twenty minutes again in the morning.
    @Test("a chapter finished this morning is left alone")
    func respectsTheGracePeriod() {
        let book = makeBook(chapters: 3)
        let eligible = AudioCleaner.eligible(
            books: [book], progress: ["book-0": finished(0.5)], now: now
        )
        #expect(eligible.isEmpty)
    }

    /// Once the whole book is done there is nothing to come back to mid-book,
    /// so the wait serves no one.
    @Test("a book finished end to end goes immediately")
    func waivesGraceForAFinishedBook() {
        let book = makeBook(chapters: 2)
        let eligible = AudioCleaner.eligible(
            books: [book],
            progress: ["book-0": finished(0.1), "book-1": finished(0.1)],
            now: now
        )
        #expect(eligible.count == 2)
    }

    @Test("an unfinished chapter is never touched")
    func keepsUnfinishedChapters() {
        let book = makeBook(chapters: 2)
        let progress = [
            "book-0": ChapterProgress(position: 300, finished: false, updatedAt: now.addingTimeInterval(-1_000_000))
        ]
        #expect(AudioCleaner.eligible(books: [book], progress: progress, now: now).isEmpty)
    }

    /// The one failure mode that would be audible.
    @Test("the chapter being played is never touched")
    func neverDeletesWhatIsPlaying() {
        let book = makeBook(chapters: 2)
        let progress = ["book-0": finished(30), "book-1": finished(30)]
        let eligible = AudioCleaner.eligible(
            books: [book], progress: progress, playing: "book-0", now: now
        )
        #expect(eligible.map(\.chapterId) == ["book-1"])
    }

    /// Deleting a prefix the renderer is about to extend would have it start
    /// again from nothing, silently.
    @Test("a chapter waiting to convert is never touched")
    func neverDeletesQueuedWork() {
        let book = makeBook(chapters: 2)
        let progress = ["book-0": finished(30), "book-1": finished(30)]
        let eligible = AudioCleaner.eligible(
            books: [book], progress: progress, queued: ["book-1"], now: now
        )
        #expect(eligible.map(\.chapterId) == ["book-0"])
    }

    @Test("a chapter with no audio has nothing to clean")
    func ignoresChaptersWithoutAudio() {
        let book = makeBook(chapters: 2, rendered: false)
        let progress = ["book-0": finished(30), "book-1": finished(30)]
        #expect(AudioCleaner.eligible(books: [book], progress: progress, now: now).isEmpty)
    }

    /// The whole point of keeping `finished` in the progress store rather than
    /// beside the audio: the audio goes, the fact of having heard it stays.
    @Test("sweeping removes the audio and leaves the chapter finished")
    func sweepResetsRenderStateOnly() async throws {
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let book = try await library.add(
            ExtractedBook(
                title: "A Book", author: nil,
                chapters: [ExtractedChapter(title: "One", text: "Words enough to chunk.")]
            ),
            language: .english
        )
        var chapter = book.chapters[0]
        chapter.renderedChunks = chapter.chunkCount
        chapter.renderedVoice = "ruth"
        try await library.update(chapter: chapter, in: book.id)

        let progress = [chapter.id: finished(30)]
        let removed = await AudioCleaner.sweep(
            library: library, books: [try #require(await library.book(book.id))],
            progress: progress, now: now
        )
        #expect(removed == [chapter.id])

        let after = try #require(await library.book(book.id)?.chapters.first)
        #expect(after.renderedChunks == 0, "it looks unrendered rather than half-there")
        #expect(after.renderedVoice == nil)
        #expect(progress[chapter.id]?.finished == true, "still finished")
    }

    /// A voice change mid-listen trims rather than discards: the chunks the
    /// listener has heard stay, everything after them goes.
    @Test("discarding from a chunk keeps the heard prefix")
    func discardsFromAChunkOnly() async throws {
        let library = try Library(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let book = try await library.add(
            ExtractedBook(
                title: "A Book", author: nil,
                chapters: [ExtractedChapter(title: "One", text: "Words enough to chunk.")]
            ),
            language: .english
        )
        let chapterId = book.chapters[0].id
        let directory = library.audioDirectory(book: book.id, chapter: chapterId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = [Float](repeating: 0, count: WavFile.sampleRate)
        for index in 0..<4 {
            try WavFile.data(from: samples).write(
                to: library.chunkURL(book: book.id, chapter: chapterId, index: index)
            )
        }
        var chapter = book.chapters[0]
        chapter.chunkCount = 4
        chapter.renderedChunks = 4
        chapter.renderedVoice = "ruth"
        try await library.update(chapter: chapter, in: book.id)

        try await library.discardAudio(chapterId: chapterId, bookId: book.id, fromChunk: 2)

        let after = try #require(await library.book(book.id)?.chapters.first)
        #expect(after.renderedChunks == 2)
        #expect(after.renderedVoice == "ruth", "the prefix is still whose it was")
        for index in 0..<4 {
            let exists = FileManager.default.fileExists(
                atPath: library.chunkURL(book: book.id, chapter: chapterId, index: index).path
            )
            #expect(exists == (index < 2), "chunk \(index)")
        }

        // From chunk zero is the old full discard.
        try await library.discardAudio(chapterId: chapterId, bookId: book.id, fromChunk: 0)
        let cleared = try #require(await library.book(book.id)?.chapters.first)
        #expect(cleared.renderedChunks == 0)
        #expect(cleared.renderedVoice == nil)
    }
}

/// The sleep timer's state machine. The fade itself is audio-engine territory
/// and is left to the ear, as the rest of this codebase leaves node behaviour.
@MainActor
struct SleepTimerTests {
    @Test("arming a timer sets a countdown")
    func armsWithCountdown() {
        let timer = SleepTimer()
        timer.start(.minutes(15))
        #expect(timer.isArmed)
        #expect(timer.mode == .minutes(15))
        #expect(timer.remaining == 900)
    }

    /// End-of-chapter has no clock: it is a flag the narrator's ticker reads.
    @Test("end of chapter asks the narrator to stop, with no countdown")
    func endOfChapterFlagsTheNarrator() {
        let timer = SleepTimer()
        var stopRequested: Bool?
        timer.attach(fade: { _ in }, stopAtChapterEnd: { stopRequested = $0 })

        timer.start(.endOfChapter)
        #expect(stopRequested == true)
        #expect(timer.remaining == nil)

        timer.cancel()
        #expect(stopRequested == false, "cancelling takes the flag back off")
        #expect(!timer.isArmed)
    }

    @Test("cancelling clears the countdown")
    func cancelClears() {
        let timer = SleepTimer()
        timer.start(.minutes(30))
        timer.cancel()
        #expect(!timer.isArmed)
        #expect(timer.remaining == nil)
    }

    /// Arming a second timer replaces the first rather than running both.
    @Test("starting again replaces the running timer")
    func restartReplaces() {
        let timer = SleepTimer()
        timer.start(.minutes(5))
        timer.start(.minutes(45))
        #expect(timer.mode == .minutes(45))
        #expect(timer.remaining == 2700)
    }

    /// Switching away from end-of-chapter must take the narrator's flag back
    /// off, or the book would stop at the chapter end anyway.
    @Test("switching from end of chapter to a clock clears the flag")
    func switchingModesClearsTheFlag() {
        let timer = SleepTimer()
        var stopRequested: Bool?
        timer.attach(fade: { _ in }, stopAtChapterEnd: { stopRequested = $0 })

        timer.start(.endOfChapter)
        timer.start(.minutes(15))
        #expect(stopRequested == false)
        #expect(timer.mode == .minutes(15))
    }
}
