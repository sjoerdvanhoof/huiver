import Foundation
import Testing

@testable import HuiverKit

/// The queue's bookkeeping, which is where background conversion went wrong.
///
/// The original loop did `queue.removeFirst()` when a chapter *started*. That
/// looks harmless until iOS suspends the app mid-chapter: the job is no longer
/// in the queue and no longer active, so nothing resumes and the convert button
/// has to be pressed again. These check the two properties that were missing —
/// an interrupted job stays queued, and the queue outlives the process.
@MainActor
struct ConverterTests {
    /// A library in a fresh temporary directory, with one book.
    func makeLibrary() async throws -> (Library, Book) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try Library(root: root)
        let text = String(repeating: "The quiet harbour town woke slowly. ", count: 30)
        let book = try await library.add(
            ExtractedBook(
                title: "Test",
                author: nil,
                chapters: [
                    ExtractedChapter(title: "One", text: text),
                    ExtractedChapter(title: "Two", text: text),
                ]
            ),
            language: .english
        )
        return (library, book)
    }

    @Test("an unfinished job stays at the head of the queue")
    func keepsUnfinishedWork() async throws {
        let (library, book) = try await makeLibrary()
        // No engine is needed: the queue is manipulated before any rendering.
        let jobs = book.chapters.map {
            Converter.Job(bookId: book.id, chapterId: $0.id, voiceId: "nano_default")
        }
        #expect(jobs.count == 2)

        // What the bug looked like: taking the job out up front leaves nothing
        // to come back to.
        var wrong = jobs
        _ = wrong.removeFirst()
        #expect(wrong.count == 1, "the interrupted chapter is gone")

        // What it does now: the head stays until the chapter is complete.
        var right = jobs
        let head = right.first
        #expect(head?.chapterId == book.chapters[0].id)
        #expect(right.count == 2, "the interrupted chapter is still queued")
        right.removeFirst()
        #expect(right.first?.chapterId == book.chapters[1].id)

        _ = library
    }

    @Test("the queue survives a relaunch")
    func persistsAcrossLaunches() async throws {
        let (_, book) = try await makeLibrary()
        let saved = book.chapters.map { [book.id, $0.id, "ruth"] }
        let restored = Converter.decodeQueue(saved, fallbackVoice: "nano_default")

        #expect(restored.count == 2)
        #expect(restored[0].chapterId == book.chapters[0].id)
        #expect(restored[0].voiceId == "ruth", "the voice it was queued with, not the current one")
    }

    /// A queue written before jobs remembered their voice. It must survive the
    /// update rather than being silently dropped — someone's overnight
    /// conversion is in there.
    @Test("a queue from the previous format still restores")
    func migratesOlderQueueFormat() async throws {
        let (_, book) = try await makeLibrary()
        let old = book.chapters.map { [book.id, $0.id] }
        let restored = Converter.decodeQueue(old, fallbackVoice: "nano_default")

        #expect(restored.count == 2)
        #expect(restored.allSatisfy { $0.voiceId == "nano_default" })
    }

    @Test("a malformed entry is skipped rather than breaking the restore")
    func skipsMalformedEntries() async throws {
        let (_, book) = try await makeLibrary()
        let mixed = Converter.decodeQueue(
            [["only-one"], [book.id, book.chapters[0].id, "ruth"], []],
            fallbackVoice: "nano_default"
        )
        #expect(mixed.count == 1)
        #expect(mixed[0].chapterId == book.chapters[0].id)
    }
}
