import Foundation
import Observation

/// Everything the screens share: the library, the engine, the voice list.
///
/// The engine is loaded lazily and its failure is kept rather than thrown, so
/// an app whose models have not been exported yet still opens and explains
/// itself instead of crashing on launch.
@MainActor
@Observable
final class AppModel {
    private(set) var books: [Book] = []
    private(set) var voices: [Voice] = []
    private(set) var narrator: Narrator?
    private(set) var converter: Converter?
    private(set) var loadFailure: String?
    private(set) var isLoading = true
    private(set) var bytesOnDisk: Int64 = 0

    /// What the engine is doing while it loads, for the preparing screen.
    /// Which processor Core ML gave each model, shown in Settings.
    private(set) var placement: [String: String] = [:]
    /// Languages the loaded models can actually read.
    private(set) var engineLanguages: [Language] = [.english]
    private(set) var preparing: ChatterboxEngine.LoadProgress?
    private(set) var preparingSince: Date?
    /// Every chapter's listening state, for the lists that draw it. Refreshed
    /// from the store rather than read through it, so a view body never has to
    /// await an actor.
    private(set) var progress: [String: ChapterProgress] = [:]
    /// Chapters this phone has asked the Mac to render, keyed by chapter id.
    /// Drawn from `ConvertRequestStore` for the same reason `progress` is drawn
    /// from the progress store: a view body cannot await an actor.
    private(set) var offloaded: [String: OffloadState] = [:]
    /// True on the run that actually compiles the models, which is the slow one
    /// worth explaining. Set once the first load finishes.
    var hasPreparedBefore: Bool {
        UserDefaults.standard.bool(forKey: "preparedOnce")
    }

    var options = SamplingOptions()

    /// Stop reading after a while. Owned here so it outlives the player sheet.
    let sleepTimer = SleepTimer()

    /// Delete a finished chapter's audio after a week. On by default — the
    /// alternative is a phone that fills up with books already listened to.
    var autoCleanup: Bool {
        get {
            UserDefaults.standard.object(forKey: "autoCleanup") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoCleanup")
            if newValue { Task { await sweepFinishedAudio() } }
        }
    }

    var selectedVoiceId: String {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "voice") }
    }


    var selectedVoice: Voice? {
        voices.first { $0.id == selectedVoiceId } ?? voices.first
    }

    /// One outstanding ask, as a chapter row needs it.
    struct OffloadState: Equatable {
        var requestId: String
        var voiceId: String
        /// The last thing the Mac said, or nil when the two have not met since
        /// the ask was made.
        var status: SyncMessage.JobStatus?
    }

    /// Also read directly by the player, to build the read-along map.
    private(set) var library: Library?
    private(set) var progressStore: ProgressStore?
    /// Read by the sync session, which is what carries these to the Mac.
    private(set) var convertRequests: ConvertRequestStore?

    init() {
        selectedVoiceId = UserDefaults.standard.string(forKey: "voice") ?? "nano_default"
    }

    /// The models and voices are bundled with the app, and the library lives in
    /// Documents so it survives an update and shows up in the Files app.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        let documents = URL.documentsDirectory
        do {
            let library = try Library(root: documents)
            self.library = library
            books = await library.all()
            bytesOnDisk = await library.bytesOnDisk()
        } catch {
            loadFailure = "Could not open the library: \(error.localizedDescription)"
            return
        }

        let progressStore = ProgressStore(root: documents)
        self.progressStore = progressStore
        progress = await progressStore.chapters()
        await progressStore.onChange { [weak self] in
            Task { @MainActor in await self?.refreshProgress() }
        }

        let convertRequests = ConvertRequestStore(root: documents)
        self.convertRequests = convertRequests
        await convertRequests.onChange { [weak self] in
            Task { @MainActor in await self?.refreshOffload() }
        }
        await refreshOffload()

        guard let resources = Bundle.main.resourceURL else {
            loadFailure = "No resources in the app bundle"
            return
        }

        do {
            voices = try VoicePack.load(from: resources.appendingPathComponent("Voices"))
        } catch {
            loadFailure = error.localizedDescription
            return
        }

        preparingSince = Date()
        do {
            let engine = try await ChatterboxEngine.load(
                models: .init(directory: resources.appendingPathComponent("Models"))
            ) { [weak self] progress in
                Task { @MainActor in self?.preparing = progress }
            }
            let narrator = Narrator(engine: engine, library: library!, progress: progressStore)
            self.narrator = narrator
            sleepTimer.attach(
                fade: { [weak narrator] seconds in narrator?.fadeOutAndPause(over: seconds) },
                stopAtChapterEnd: { [weak narrator] stop in
                    narrator?.stopAtChapterEnd = stop
                    if !stop { narrator?.cancelFade() }
                },
                cancelFade: { [weak narrator] in narrator?.cancelFade() }
            )
            let converter = Converter(engine: engine, library: library!)
            converter.voices = voices
            converter.didChange = { [weak self] in
                Task { await self?.refresh() }
            }
            self.converter = converter
            // Anything left queued by a previous run carries on now, without
            // the button having to be pressed again.
            if let voice = selectedVoice {
                converter.restore(voice: voice, options: options)
            }
            placement = await engine.placement
            engineLanguages = engine.languages
            UserDefaults.standard.set(true, forKey: "preparedOnce")
        } catch {
            loadFailure = error.localizedDescription
        }
        preparing = nil
        preparingSince = nil
        if autoCleanup { await sweepFinishedAudio() }
    }

    /// Delete the audio of chapters finished long enough ago to be done with.
    ///
    /// Never touches what is playing or what is queued to render — see
    /// `AudioCleaner`, which is where the rule lives and is tested.
    func sweepFinishedAudio() async {
        guard autoCleanup, let library else { return }
        let removed = await AudioCleaner.sweep(
            library: library,
            books: books,
            progress: progress,
            playing: narrator?.chapterId,
            queued: Set((converter?.queue.map(\.chapterId) ?? []) + [converter?.active?.chapterId].compactMap { $0 })
        )
        guard !removed.isEmpty else { return }
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
    }

    func importBook(from url: URL) async {
        guard let library else { return }
        // A file handed over by the document picker lives outside the sandbox
        // until it is read, and the scope has to be given back afterwards.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            let extracted = try Extract.book(from: data, filename: filename)
            _ = try await library.add(extracted, source: (data: data, filename: filename))
            books = await library.all()
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    /// Where a book's cover image is, if the EPUB had one.
    func coverURL(for book: Book) -> URL? {
        library?.coverURL(book)
    }

    func setLanguage(_ language: Language, for book: Book) async {
        guard let library else { return }
        try? await library.setLanguage(language, for: book.id)
        books = await library.all()
    }

    /// Can the engine read this book, or will it mispronounce it?
    func canSpeak(_ book: Book) -> Bool {
        engineLanguages.contains { $0.code == book.languageCode }
    }

    func delete(_ book: Book) async {
        guard let library else { return }
        if narrator?.chapterId != nil, book.chapters.contains(where: { $0.id == narrator?.chapterId }) {
            narrator?.stop()
        }
        try? await library.remove(book.id)
        await progressStore?.removeBook(book.id, chapterIds: book.chapters.map(\.id))
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
        await refreshProgress()
    }

    /// Throw away a chapter's audio and render it again.
    ///
    /// The way to pick up an improvement to the chunker or the sampler on a
    /// book that is already converted — the audio on disk is only ever reused,
    /// never revisited, so without this a chapter keeps whatever it was first
    /// rendered with for good.
    func rerender(chapter: Chapter, in book: Book) async {
        guard let library, let converter, let voice = selectedVoice else { return }
        if narrator?.chapterId == chapter.id { narrator?.stop() }
        converter.cancel(chapter.id)
        // Let the cancelled pass wind down before deleting its directory —
        // discarding immediately raced the chunk still being written.
        await converter.waitUntilIdle()
        try? await library.discardAudio(chapterId: chapter.id, bookId: book.id)

        // Re-chunk against the current chunker now the audio that pinned the
        // old boundaries is gone.
        if var updated = await library.book(book.id)?.chapters.first(where: { $0.id == chapter.id }) {
            updated.chunkCount = Chunker.chunkWithSentenceLead(updated.text).count
            updated.chunkerVersion = Chunker.version
            try? await library.update(chapter: updated, in: book.id)
            books = await library.all()
            if let fresh = await library.book(book.id) {
                converter.convert(book: fresh, chapter: updated, voice: voice, options: options)
            }
        }
        await refresh()
    }

    /// Turn a chapter's finished flag on or off by hand.
    ///
    /// Un-finishing is how you go back to a chapter you want to hear again;
    /// finishing by hand is how you skip one without listening to it.
    func setFinished(_ finished: Bool, chapter: Chapter, in book: Book) async {
        await progressStore?.setFinished(finished, chapterId: chapter.id, bookId: book.id)
        await progressStore?.flush()
        await refreshProgress()
    }

    // MARK: - Asking the Mac

    /// Ask the Mac to render this chapter, next time the two are in the same
    /// room.
    ///
    /// Deliberately not a transfer: the ask is written down and travels in the
    /// next manifest, so it can be made with the Mac asleep, elsewhere, or not
    /// yet holding the book. Nothing here starts a sync.
    func requestConversionOnMac(chapter: Chapter, in book: Book) async {
        guard let convertRequests,
              let contentId = book.contentId,
              let index = book.chapters.firstIndex(where: { $0.id == chapter.id }),
              let voice = selectedVoice
        else { return }
        await convertRequests.add(
            contentId: contentId,
            chapterIndex: index,
            textHash: chapter.textHash ?? ContentIdentity.chapterHash(chapter.text),
            voiceId: voice.id
        )
        await refreshOffload()
    }

    /// Take the ask back. The Mac finds out at the next sync, by the request no
    /// longer being in the manifest; a chapter it has already started is its
    /// own business, and the audio is welcome if it arrives.
    func cancelMacRequest(chapter: Chapter) async {
        guard let convertRequests, let state = offloaded[chapter.id] else { return }
        await convertRequests.remove(requestId: state.requestId)
        await refreshOffload()
    }

    /// Turn the stored asks into something keyed by chapter id, dropping any
    /// the library says are already satisfied.
    func refreshOffload() async {
        guard let convertRequests else { return }
        let byContent = Dictionary(
            books.compactMap { book in book.contentId.map { ($0, book) } },
            uniquingKeysWith: { first, _ in first }
        )
        var map: [String: OffloadState] = [:]
        for request in await convertRequests.pending(against: books) {
            guard let book = byContent[request.contentId],
                  book.chapters.indices.contains(request.chapterIndex)
            else { continue }
            map[book.chapters[request.chapterIndex].id] = OffloadState(
                requestId: request.requestId,
                voiceId: request.voiceId,
                status: await convertRequests.status(requestId: request.requestId)
            )
        }
        offloaded = map
    }

    func refresh() async {
        guard let library else { return }
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
        await refreshProgress()
        await refreshOffload()
    }

    func refreshProgress() async {
        guard let progressStore else { return }
        progress = await progressStore.chapters()
    }

    /// Has this chapter been listened to the end?
    func isFinished(_ chapter: Chapter) -> Bool {
        progress[chapter.id]?.finished ?? false
    }

    /// How far into a chapter the listener got, or nil if they never started
    /// it. A finished chapter reports nothing: its bar belongs at neither end.
    func position(in chapter: Chapter) -> Double? {
        guard let record = progress[chapter.id], !record.finished, record.position > 1 else {
            return nil
        }
        return record.position
    }

    /// What Resume should open: where the listener was, or the first chapter
    /// they have not finished.
    ///
    /// The stored chapter wins even when an earlier one is unfinished — going
    /// back to skipped chapters is a choice, and the button that means "carry
    /// on" should carry on.
    func resumeTarget(for book: Book) -> (chapter: Chapter, position: Double)? {
        if let chapter = lastChapter(of: book), !isFinished(chapter) {
            return (chapter, progress[chapter.id]?.position ?? 0)
        }
        guard let next = book.chapters.first(where: { !isFinished($0) }) else { return nil }
        return (next, progress[next.id]?.position ?? 0)
    }

    /// The chapter of this book that was touched most recently.
    private func lastChapter(of book: Book) -> Chapter? {
        book.chapters
            .compactMap { chapter in progress[chapter.id].map { (chapter, $0.updatedAt) } }
            .max { $0.1 < $1.1 }?.0
    }

    func clearFailure() { loadFailure = nil }
}
