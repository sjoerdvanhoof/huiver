import Foundation

/// One chapter's listening state.
///
/// Deliberately shaped for sync as well as for the phone: a position, whether
/// it was finished, and when that last changed. Two devices resolve a
/// disagreement by taking the newer `updatedAt`, which is the whole conflict
/// story — one person cannot listen in two places at once, so anything cleverer
/// would be machinery for a case that does not arise.
public struct ChapterProgress: Codable, Sendable, Equatable {
    /// Where playback got to, in chapter seconds.
    public var position: Double
    /// Listened to the end. Survives the audio being deleted, which is what
    /// lets the cleanup sweep throw away a finished chapter without losing the
    /// fact that it was finished.
    public var finished: Bool
    public var updatedAt: Date

    public init(position: Double = 0, finished: Bool = false, updatedAt: Date = Date()) {
        self.position = position
        self.finished = finished
        self.updatedAt = updatedAt
    }
}

/// Where a book was left off, so Resume opens the right chapter.
public struct BookProgress: Codable, Sendable, Equatable {
    public var lastChapterId: String?
    public var updatedAt: Date

    public init(lastChapterId: String? = nil, updatedAt: Date = Date()) {
        self.lastChapterId = lastChapterId
        self.updatedAt = updatedAt
    }
}

/// Listening positions, in `Documents/progress.json`.
///
/// Kept out of `library.json` on purpose. The library is rewritten whole on
/// every change and holds every chapter's full text; a position that moves four
/// times a second has no business in a file like that. This one holds a few
/// hundred bytes per chapter and nothing else.
///
/// Writes land in memory immediately and reach the disk on a timer, or at the
/// moments that actually matter — pausing, stopping, the app going away. Losing
/// the last few seconds of a position to a crash is a shrug; blocking the
/// player on a write is not.
public actor ProgressStore {
    private struct Snapshot: Codable {
        var version: Int = 1
        var books: [String: BookProgress] = [:]
        var chapters: [String: ChapterProgress] = [:]
    }

    /// How long a position may sit in memory before it is written down.
    static let flushDelay: Duration = .seconds(5)

    private let url: URL
    private var snapshot: Snapshot
    private var pendingFlush: Task<Void, Never>?
    private var observer: (@Sendable () -> Void)?

    public init(root: URL) {
        self.url = root.appendingPathComponent("progress.json")
        // A progress file that will not decode is an annoyance, not a
        // catastrophe: the worst case is that positions start again from zero.
        // Same posture as the library — never refuse to launch over it.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.snapshot = decoded
        } else {
            self.snapshot = Snapshot()
        }
    }

    /// Called when something a list view would draw differently has changed —
    /// a chapter finishing, a book being opened at a new chapter, a flush. Not
    /// called for every position tick: the player already shows the position it
    /// is reporting, and invalidating the library four times a second to redraw
    /// a progress bar nobody is looking at is pure waste.
    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        observer = handler
    }

    public func chapter(_ chapterId: String) -> ChapterProgress? {
        snapshot.chapters[chapterId]
    }

    public func book(_ bookId: String) -> BookProgress? {
        snapshot.books[bookId]
    }

    /// Every chapter's state at once, for a view that is about to draw a list
    /// of them.
    public func chapters() -> [String: ChapterProgress] { snapshot.chapters }

    public func setPosition(_ seconds: Double, chapterId: String, bookId: String) {
        var record = snapshot.chapters[chapterId] ?? ChapterProgress()
        record.position = max(0, seconds)
        record.updatedAt = Date()
        let isNew = snapshot.chapters[chapterId] == nil
        snapshot.chapters[chapterId] = record
        snapshot.books[bookId] = BookProgress(lastChapterId: chapterId, updatedAt: Date())
        scheduleFlush()
        // A chapter appearing for the first time is a visible change (a book
        // goes from untouched to in-progress); the ticks after it are not.
        if isNew { observer?() }
    }

    public func setFinished(_ finished: Bool, chapterId: String, bookId: String) {
        var record = snapshot.chapters[chapterId] ?? ChapterProgress()
        let changed = record.finished != finished
        record.finished = finished
        record.updatedAt = Date()
        snapshot.chapters[chapterId] = record
        snapshot.books[bookId] = BookProgress(lastChapterId: chapterId, updatedAt: Date())
        scheduleFlush()
        if changed { observer?() }
    }

    /// Forget a book's progress, when the book itself is deleted.
    public func removeBook(_ bookId: String, chapterIds: [String]) {
        snapshot.books.removeValue(forKey: bookId)
        for id in chapterIds { snapshot.chapters.removeValue(forKey: id) }
        scheduleFlush()
        observer?()
    }

    /// Merge a record that came from another device, newer-wins.
    ///
    /// Returns whether it was taken. The caller does not need to know, but the
    /// sync session logs it and the tests assert on it.
    @discardableResult
    public func merge(
        _ incoming: ChapterProgress, chapterId: String, bookId: String
    ) -> Bool {
        if let existing = snapshot.chapters[chapterId], existing.updatedAt >= incoming.updatedAt {
            return false
        }
        snapshot.chapters[chapterId] = incoming
        // The book pointer follows the chapter that won, so resuming on this
        // device opens what was being listened to on the other one.
        if let existing = snapshot.books[bookId], existing.updatedAt >= incoming.updatedAt {
            // Except when this device has more recent book-level activity.
        } else {
            snapshot.books[bookId] = BookProgress(
                lastChapterId: chapterId, updatedAt: incoming.updatedAt
            )
        }
        scheduleFlush()
        observer?()
        return true
    }

    /// Write now. Called when pausing, stopping, and when the app leaves the
    /// screen — the three moments where the next thing to happen might be the
    /// process going away.
    public func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        write()
        observer?()
    }

    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(for: ProgressStore.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.flushFromTimer()
        }
    }

    private func flushFromTimer() {
        pendingFlush = nil
        write()
        observer?()
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
