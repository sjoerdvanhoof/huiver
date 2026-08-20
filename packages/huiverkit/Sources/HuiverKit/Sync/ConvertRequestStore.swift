import Foundation

/// The asks this device has made of the other one, in
/// `Documents/convert-requests.json`.
///
/// Small, rarely written, and outliving the session that made it — a request
/// survives the phone being put down, the Mac being asleep and the app being
/// force quit, because the Mac may not even have the book yet when the request
/// is made. That is the whole reason this is a file rather than a property on
/// the sync model.
///
/// Nothing here is authoritative about *rendering*: the Mac's queue is. What is
/// kept is the intent plus the last thing the Mac said about it, so a phone
/// that has not synced in an hour can still say what it is waiting for instead
/// of showing an empty screen.
public actor ConvertRequestStore {
    private struct Snapshot: Codable {
        var version: Int = 1
        var requests: [ConvertRequest] = []
        /// Keyed by request id, so a status outlives the message that carried
        /// it and a re-sent request keeps the state it already had.
        var statuses: [String: SyncMessage.JobStatus] = [:]
    }

    private let url: URL
    private var snapshot: Snapshot
    private var observer: (@Sendable () -> Void)?

    public init(root: URL) {
        self.url = root.appendingPathComponent("convert-requests.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.snapshot = decoded
        } else {
            // Same posture as the library and the progress store: a file that
            // will not decode costs the user a button press, not a launch.
            self.snapshot = Snapshot()
        }
    }

    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        observer = handler
    }

    // MARK: - Making one

    /// Ask for a chapter to be rendered elsewhere.
    ///
    /// Idempotent: the id comes from the text and the voice, so asking twice
    /// leaves one request and keeps the status the first one collected.
    @discardableResult
    public func add(
        contentId: String, chapterIndex: Int, textHash: String, voiceId: String
    ) -> ConvertRequest {
        let request = ConvertRequest(
            contentId: contentId,
            chapterIndex: chapterIndex,
            textHash: textHash,
            voiceId: voiceId
        )
        guard !snapshot.requests.contains(where: { $0.requestId == request.requestId }) else {
            return request
        }
        snapshot.requests.append(request)
        write()
        observer?()
        return request
    }

    public func remove(requestId: String) {
        let before = snapshot.requests.count
        snapshot.requests.removeAll { $0.requestId == requestId }
        snapshot.statuses[requestId] = nil
        guard snapshot.requests.count != before else { return }
        write()
        observer?()
    }

    public func remove(textHash: String, voiceId: String) {
        remove(requestId: ContentIdentity.requestId(textHash: textHash, voiceId: voiceId))
    }

    // MARK: - Reading it

    public func all() -> [ConvertRequest] { snapshot.requests }

    public func status(requestId: String) -> SyncMessage.JobStatus? {
        snapshot.statuses[requestId]
    }

    /// What a chapter row needs to draw itself: the request, if this chapter is
    /// one that was asked for in this voice, and whatever the Mac last said.
    public func state(
        textHash: String, voiceId: String
    ) -> (request: ConvertRequest, status: SyncMessage.JobStatus?)? {
        let id = ContentIdentity.requestId(textHash: textHash, voiceId: voiceId)
        guard let request = snapshot.requests.first(where: { $0.requestId == id }) else {
            return nil
        }
        return (request, snapshot.statuses[id])
    }

    /// Everything worth sending, having first dropped what the local library
    /// says is no longer worth asking for.
    ///
    /// Pruning happens here rather than when audio arrives because this is the
    /// one moment the two are certain to be compared: a request is retired when
    /// the chapter it names is complete locally, whether the audio came from
    /// the Mac, from a local render, or from a book that was deleted and
    /// re-imported.
    public func pending(against books: [Book]) -> [ConvertRequest] {
        let byContent = Dictionary(
            books.compactMap { book in book.contentId.map { ($0, book) } },
            uniquingKeysWith: { first, _ in first }
        )
        var kept: [ConvertRequest] = []
        for request in snapshot.requests {
            guard let book = byContent[request.contentId],
                  book.chapters.indices.contains(request.chapterIndex)
            else { continue }  // the book left; the ask goes with it
            let chapter = book.chapters[request.chapterIndex]
            if chapter.isComplete, chapter.renderedVoice == request.voiceId { continue }
            kept.append(request)
        }
        guard kept.count != snapshot.requests.count else { return kept }
        let live = Set(kept.map(\.requestId))
        snapshot.requests = kept
        snapshot.statuses = snapshot.statuses.filter { live.contains($0.key) }
        write()
        observer?()
        return kept
    }

    // MARK: - What the other device said

    /// A status for a request this device made. Statuses for anything else are
    /// dropped: they belong to a phone that is not this one.
    public func record(_ status: SyncMessage.JobStatus) {
        guard snapshot.requests.contains(where: { $0.requestId == status.requestId }) else {
            return
        }
        guard snapshot.statuses[status.requestId] != status else { return }
        snapshot.statuses[status.requestId] = status
        write()
        observer?()
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
