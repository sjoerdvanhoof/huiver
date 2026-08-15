import Foundation

/// Throw away audio nobody is going to listen to again.
///
/// A chapter is about 173 MB an hour on the phone, so a book listened to and
/// left behind is a gigabyte doing nothing. What makes deleting it safe is that
/// `finished` lives in the progress store rather than with the audio: the files
/// go, the fact that they were heard stays, and the chapter can be re-rendered
/// — or, once the Mac is paired, simply fetched again — if it is ever wanted.
///
/// The eligibility rule is a pure function so it can be tested against a fixed
/// clock rather than by waiting a week.
public enum AudioCleaner {
    public struct Policy: Sendable, Equatable {
        /// How long a finished chapter is kept before its audio goes.
        ///
        /// Not zero, because "finished" happens the instant the last second
        /// plays — including when someone dozed off and wants the end of the
        /// chapter again in the morning.
        public var graceDays: Int

        public init(graceDays: Int = 7) {
            self.graceDays = graceDays
        }

        public static let `default` = Policy()
    }

    /// Which chapters' audio may go.
    ///
    /// - Parameters:
    ///   - playing: the chapter currently loaded in the player, which is never
    ///     eligible however finished it is — deleting the files out from under
    ///     a playing chapter is the one way to make this feature audible.
    ///   - queued: chapters waiting to be converted or being converted now.
    ///     Deleting a prefix the renderer is about to extend would have it
    ///     silently start again from nothing.
    public static func eligible(
        books: [Book],
        progress: [String: ChapterProgress],
        playing: String? = nil,
        queued: Set<String> = [],
        policy: Policy = .default,
        now: Date = Date()
    ) -> [(bookId: String, chapterId: String)] {
        var out: [(bookId: String, chapterId: String)] = []

        for book in books {
            // A book finished from end to end is done being read; the grace
            // period is for the chapter someone fell asleep in, which by
            // definition is not the whole book.
            let wholeBookFinished = !book.chapters.isEmpty
                && book.chapters.allSatisfy { progress[$0.id]?.finished == true }

            for chapter in book.chapters {
                guard chapter.renderedChunks > 0 else { continue }
                guard chapter.id != playing, !queued.contains(chapter.id) else { continue }
                guard let record = progress[chapter.id], record.finished else { continue }

                if wholeBookFinished {
                    out.append((book.id, chapter.id))
                    continue
                }
                let grace = TimeInterval(policy.graceDays * 24 * 60 * 60)
                if now.timeIntervalSince(record.updatedAt) >= grace {
                    out.append((book.id, chapter.id))
                }
            }
        }
        return out
    }

    /// Run the sweep. Returns the chapters whose audio was removed.
    @discardableResult
    public static func sweep(
        library: Library,
        books: [Book],
        progress: [String: ChapterProgress],
        playing: String? = nil,
        queued: Set<String> = [],
        policy: Policy = .default,
        now: Date = Date()
    ) async -> [String] {
        let targets = eligible(
            books: books, progress: progress, playing: playing, queued: queued,
            policy: policy, now: now
        )
        var removed: [String] = []
        for target in targets {
            // The same path a voice change takes: the files go and the
            // chapter's rendered counters reset, so it looks unrendered rather
            // than rendered-but-missing.
            try? await library.discardAudio(chapterId: target.chapterId, bookId: target.bookId)
            removed.append(target.chapterId)
        }
        return removed
    }
}
