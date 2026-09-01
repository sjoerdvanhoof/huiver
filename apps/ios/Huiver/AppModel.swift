import Foundation
import Observation
import UserNotifications

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
    /// A book that would not import. Its own channel, not `loadFailure`: a bad
    /// EPUB is not an engine problem, and showing it under a header that says
    /// "Engine" sent people debugging the wrong thing.
    var importFailure: String?
    private(set) var isLoading = true
    private(set) var bytesOnDisk: Int64 = 0

    /// What the engine is doing while it loads, for the preparing screen.
    /// Which processor Core ML gave each model, shown in Settings.
    private(set) var placement: [String: String] = [:]
    /// Languages the loaded models can actually read.
    private(set) var engineLanguages: [Language] = [.english]
    /// Where the compiled models are, kept because cloning needs them long
    /// after `load` has finished with them.
    private(set) var modelDirectory: URL?
    /// Whether a cloner package is installed beside the engine. Not a loaded
    /// cloner: see `cloneVoice` for why one is never held.
    private(set) var canCloneVoices = false
    /// Where voices recorded on this phone are written — the same directory
    /// sync delivers into, so one `VoicePack.load` finds both.
    private(set) var recordedVoices: URL?
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
    /// What the Mac offered in its most recent manifest, keyed by local chapter.
    private(set) var macAudio: [String: AudioManifest] = [:]
    /// True on the run that actually compiles the models, which is the slow one
    /// worth explaining. Set once the first load finishes.
    var hasPreparedBefore: Bool {
        UserDefaults.standard.bool(forKey: "preparedOnce")
    }

    /// Remembered across launches — a slider is a preference, not a session.
    var options = SamplingOptions() {
        didSet {
            guard let data = try? JSONEncoder().encode(options) else { return }
            UserDefaults.standard.set(data, forKey: "samplingOptions")
        }
    }

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

    func recordMacManifest(_ manifest: SyncMessage.Manifest) {
        let localByContent = Dictionary(
            books.compactMap { book in book.contentId.map { ($0, book) } },
            uniquingKeysWith: { first, _ in first }
        )
        var available: [String: AudioManifest] = [:]
        for remoteBook in manifest.books {
            guard let localBook = localByContent[remoteBook.contentId] else { continue }
            for remoteChapter in remoteBook.chapters {
                guard localBook.chapters.indices.contains(remoteChapter.index),
                      let audio = remoteChapter.audio, audio.renderedChunks > 0
                else { continue }
                available[localBook.chapters[remoteChapter.index].id] = audio
            }
        }
        macAudio = available
    }

    /// Also read directly by the player, to build the read-along map.
    private(set) var library: Library?
    private(set) var progressStore: ProgressStore?
    /// Read by the sync session, which is what carries these to the Mac.
    private(set) var convertRequests: ConvertRequestStore?

    init() {
        selectedVoiceId = UserDefaults.standard.string(forKey: "voice") ?? "nano_default"
        // Observers do not fire in init, so this neither re-saves what it read
        // nor loses the defaults when nothing was stored.
        if let data = UserDefaults.standard.data(forKey: "samplingOptions"),
           let stored = try? JSONDecoder().decode(SamplingOptions.self, from: data) {
            options = stored
        }
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
            await PronunciationStore.shared.configure(root: documents)
            await PreflightStore.shared.configure(root: documents)
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
            // Two directories: the pack in the bundle, plus whatever voices
            // sync has delivered into Documents/voices — the same directory
            // `SyncModel` hands the session. Without the second, a synced
            // voice was written to disk and never seen again.
            voices = try VoicePack.load(
                from: resources.appendingPathComponent("Voices"),
                plus: documents.appendingPathComponent("voices")
            )
        } catch {
            loadFailure = error.localizedDescription
            return
        }

        let models = resources.appendingPathComponent("Models")
        modelDirectory = models
        recordedVoices = documents.appendingPathComponent("voices")
        // The file, not the model: a cloner is 262 MB and holding one for a
        // button that is usually not pressed would cost more than it is worth.
        canCloneVoices = VoiceCloner.isAvailable(in: models)

        preparingSince = Date()
        do {
            let engine = try await ChatterboxEngine.load(
                models: .init(directory: models)
            ) { [weak self] progress in
                Task { @MainActor in self?.preparing = progress }
            }
            // A voice cloned for the Mac's multilingual model has the wrong
            // tensor shapes for Nano, and sync will happily deliver one.
            // Offering it as a narrator fails on the first chunk, so the
            // roster keeps what this engine can actually read. The Mac ships
            // its own clones under the same lv_ ids, and a synced copy wins
            // the merge — so when the override is unreadable, the bundled
            // original comes back rather than the voice disappearing.
            let bundled = (try? VoicePack.load(
                from: resources.appendingPathComponent("Voices")
            )) ?? []
            var readable: [Voice] = []
            for voice in voices {
                if await engine.canRead(voice) {
                    readable.append(voice)
                } else if let original = bundled.first(where: { $0.id == voice.id }),
                          await engine.canRead(original) {
                    readable.append(original)
                }
            }
            voices = readable
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
            if let pending = pendingClone {
                pendingClone = nil
                await runClone(samples: pending.samples, name: pending.name)
            }
        } catch {
            loadFailure = error.localizedDescription
            if pendingClone != nil {
                pendingClone = nil
                cloneFailure = "The voice model failed to load, so your recording "
                    + "couldn't become a voice yet. You can record again in Settings."
            }
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
            importFailure = error.localizedDescription
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

    /// Throw away every chapter's rendered audio for a book, keeping the book.
    ///
    /// The space-back story: a finished book's audio is most of what the app
    /// holds on disk, and deleting the whole book to reclaim it also deleted
    /// the text and the positions.
    func clearRenderedAudio(for book: Book) async {
        guard let library else { return }
        if narrator?.chapterId != nil,
           book.chapters.contains(where: { $0.id == narrator?.chapterId }) {
            narrator?.stop()
        }
        if let converter {
            for chapter in book.chapters { converter.cancel(chapter.id) }
            // Let a cancelled pass wind down before deleting its directory —
            // discarding immediately races the chunk still being written.
            await converter.waitUntilIdle()
        }
        try? await library.discardAudio(bookId: book.id)
        books = await library.all()
        bytesOnDisk = await library.bytesOnDisk()
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
            let locale = LocaleProfile(book.spokenLocaleIdentifier)
            let profile = LanguageProcessorRegistry.processor(for: book.languageCode)
                .chunkingProfile(locale: locale)
            updated.chunkCount = Chunker.chunkWithSentenceLead(updated.text, profile: profile).count
            updated.chunkerVersion = Chunker.version
            updated.chunkingProfile = profile.id
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

    // MARK: - Export

    /// The export in flight, for the book screen's progress bar.
    private(set) var exporting: (bookId: String, fraction: Double)?
    var exportFailure: String?

    /// The book's fully rendered chapters as one chapter-marked `.m4b` in the
    /// temporary directory, ready for the share sheet — AirDrop, Files, Books.
    func exportAudiobook(_ book: Book) async -> URL? {
        guard let library, exporting == nil else { return nil }
        exporting = (book.id, 0)
        defer { exporting = nil }

        let chapters = book.chapters.filter(\.isComplete).map { chapter in
            AudiobookExporter.Chapter(
                title: chapter.title,
                chunkURLs: (0..<chapter.renderedChunks).map {
                    library.chunkURL(book: book.id, chapter: chapter.id, index: $0)
                }
            )
        }
        let metadata = AudiobookExporter.BookMetadata(
            title: book.title,
            author: book.author,
            cover: coverURL(for: book).flatMap { try? Data(contentsOf: $0) }
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(AudiobookExporter.filename(book.title) + ".m4b")
        // Percent steps only: the writer reports every buffer, and a
        // main-actor hop per 1.3 s of audio adds up over a long book.
        let reported = ReportedPercent()
        let update: @Sendable (Double) -> Void = { [weak self] fraction in
            guard reported.advance(to: fraction) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.exporting?.bookId == book.id else { return }
                self.exporting = (book.id, fraction)
            }
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try AudiobookExporter.writeM4B(
                    chapters: chapters, metadata: metadata, to: destination, progress: update
                )
            }.value
            return destination
        } catch {
            exportFailure = error.localizedDescription
            return nil
        }
    }

    /// One rendered chapter as a tagged `.m4a` in the temporary directory.
    func exportChapter(_ chapter: Chapter, in book: Book) async -> URL? {
        guard let library, exporting == nil, chapter.isComplete else { return nil }
        exporting = (book.id, 0)
        defer { exporting = nil }
        let number = book.chapters.firstIndex { $0.id == chapter.id }.map { $0 + 1 }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                AudiobookExporter.filename(chapter.title, number: number) + ".m4a"
            )
        let urls = (0..<chapter.renderedChunks).map {
            library.chunkURL(book: book.id, chapter: chapter.id, index: $0)
        }
        let metadata = AudiobookExporter.BookMetadata(
            title: book.title,
            author: book.author,
            cover: coverURL(for: book).flatMap { try? Data(contentsOf: $0) }
        )
        do {
            try await Task.detached(priority: .userInitiated) {
                try AudiobookExporter.writeChapterM4A(
                    chunkURLs: urls,
                    title: chapter.title,
                    track: number.map { ($0, book.chapters.count) },
                    metadata: metadata,
                    to: destination
                )
            }.value
            return destination
        } catch {
            exportFailure = error.localizedDescription
            return nil
        }
    }

    /// Cross-thread percent throttle for export progress.
    private final class ReportedPercent: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1
        func advance(to fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            return lock.withLock {
                guard percent > last else { return false }
                last = percent
                return true
            }
        }
    }

    // MARK: - Recording a voice

    /// Turn a recording into a voice this phone can read with.
    ///
    /// The cloner is loaded here and dropped on the way out, rather than held
    /// beside the engine the way the Mac holds its own. Four models and their
    /// weights already sit in memory — 736 MB of them — and iOS answers a
    /// high-water mark it does not like by killing the app with no crash
    /// report. 262 MB more, permanently, for a button most sessions never
    /// press, is not a trade worth making; a few seconds of loading when the
    /// button *is* pressed is.
    ///
    /// The recording never leaves the phone. What is written is the five
    /// tensors of a voice, none of which can be turned back into audio.
    /// A recording waiting for the engine. Onboarding lets someone read the
    /// passage while the models are still compiling; the clone runs the moment
    /// the first load finishes instead of blocking the flow on it.
    struct PendingClone {
        var samples: [Float]
        var name: String
    }

    private(set) var pendingClone: PendingClone?
    private(set) var cloneInFlight = false
    /// Surfaced as its own alert, like `importFailure`: a failed clone is not
    /// the engine's fault and should say what to do next.
    var cloneFailure: String?

    /// Clone now if the engine is up; otherwise remember the take and clone
    /// when `load()` finishes.
    func submitClone(samples: [Float], name: String) {
        if narrator != nil {
            Task { await runClone(samples: samples, name: name) }
        } else {
            pendingClone = PendingClone(samples: samples, name: name)
        }
    }

    private func runClone(samples: [Float], name: String) async {
        cloneInFlight = true
        defer { cloneInFlight = false }
        do {
            _ = try await cloneVoice(
                from: samples,
                name: name,
                language: engineLanguages.first ?? .english
            )
        } catch {
            cloneFailure = "Your voice couldn't be created: \(error.localizedDescription) "
                + "You can record again in Settings."
        }
    }

    func cloneVoice(from recording: [Float], name: String, language: Language) async throws -> Voice {
        guard let modelDirectory, let recordedVoices, let resources = Bundle.main.resourceURL
        else { throw VoiceCloner.CloneError.unavailable }

        // An id from the name, and a number if that name is taken: two voices
        // called "Me" must not become one file.
        let base = "rec_" + name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        var id = base.isEmpty ? "rec_voice" : base
        var suffix = 2
        while voices.contains(where: { $0.id == id }) {
            id = "\(base)_\(suffix)"
            suffix += 1
        }

        let cloner = try await VoiceCloner(models: modelDirectory)
        let voice = try await cloner.clone(
            recording,
            id: id,
            name: name.isEmpty ? "My voice" : name,
            detail: "recorded in \(language.name) on this phone",
            persona: "Your own voice, cloned from a short recording.",
            language: language.code
        )
        try VoicePack.write(voice, to: recordedVoices)
        voices = try VoicePack.load(
            from: resources.appendingPathComponent("Voices"), plus: recordedVoices
        )
        selectedVoiceId = voice.id
        return voice
    }

    /// Whether this voice was made here, which is the only kind that can be
    /// deleted — the bundled ones come back with the app.
    func isRecorded(_ voice: Voice) -> Bool {
        guard let recordedVoices else { return false }
        return FileManager.default.fileExists(
            atPath: recordedVoices.appendingPathComponent("\(voice.id).voice").path
        )
    }

    func deleteRecordedVoice(_ voice: Voice) {
        guard let recordedVoices, let resources = Bundle.main.resourceURL,
              isRecorded(voice)
        else { return }
        try? VoicePack.remove(id: voice.id, from: recordedVoices)
        voices = (try? VoicePack.load(
            from: resources.appendingPathComponent("Voices"), plus: recordedVoices
        )) ?? voices
        // Whatever is left, so the app is never pointing at a voice that has
        // gone. Audio already rendered in it keeps playing: see `Narrator.route`.
        if selectedVoiceId == voice.id { selectedVoiceId = voices.first?.id ?? "nano_default" }
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

    /// Every unrendered chapter of a book, asked for at once — "convert this
    /// book on the Mac and I'll walk away." The request store dedupes by
    /// content, so asking again for a book half-asked-for costs nothing.
    func requestBookConversionOnMac(_ book: Book) async {
        guard let convertRequests,
              let contentId = book.contentId,
              let voice = selectedVoice
        else { return }
        for (index, chapter) in book.chapters.enumerated() where !chapter.isComplete {
            await convertRequests.add(
                contentId: contentId,
                chapterIndex: index,
                textHash: chapter.textHash ?? ContentIdentity.chapterHash(chapter.text),
                voiceId: voice.id
            )
        }
        await refreshOffload()
    }

    /// A chosen run of chapters, asked for at once — what "convert from the
    /// listening position" sends to the Mac. Same posture as the whole-book
    /// ask: the request store dedupes, so overlap with earlier asks is free.
    func requestConversionOnMac(chapters: [Chapter], in book: Book) async {
        guard let convertRequests,
              let contentId = book.contentId,
              let voice = selectedVoice
        else { return }
        for chapter in chapters where !chapter.isComplete {
            guard let index = book.chapters.firstIndex(where: { $0.id == chapter.id }) else {
                continue
            }
            await convertRequests.add(
                contentId: contentId,
                chapterIndex: index,
                textHash: chapter.textHash ?? ContentIdentity.chapterHash(chapter.text),
                voiceId: voice.id
            )
        }
        await refreshOffload()
    }

    /// Queue a run of chapters on this phone's own converter, in the order
    /// given — the unpaired cut of "convert from the listening position".
    func convert(chapters: [Chapter], in book: Book) {
        guard let converter, let voice = selectedVoice else { return }
        for chapter in chapters {
            converter.convert(book: book, chapter: chapter, voice: voice, options: options)
        }
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
        await refreshProgress()
        await refreshOffload()
        updateConversionSurface()
    }

    /// The disk total is a full walk of the audio tree, so it is refreshed
    /// when the Settings screen asks — not on the converter's every chunk,
    /// which used to stat thousands of files a minute during a render.
    func refreshStorage() async {
        guard let library else { return }
        bytesOnDisk = await library.bytesOnDisk()
    }

    /// A conversion takes an hour of compute per hour of audio, so its end is
    /// worth a notification — the natural companion to a converter that can
    /// only run while the app is open or in a granted background slot.
    private var wasConverting = false

    private func updateConversionSurface() {
        let converting = converter?.isBusy ?? false
        let drained = converter?.queue.isEmpty ?? true
        if wasConverting, !converting, drained {
            notifyConversionFinished(failure: converter?.failure)
        }
        wasConverting = converting || !drained
    }

    private func notifyConversionFinished(failure: String?) {
        let centre = UNUserNotificationCenter.current()
        centre.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            if let failure {
                content.title = "Conversion stopped"
                content.body = failure
            } else {
                content.title = "Conversion finished"
                content.body = "The queue is done — every chapter is rendered."
            }
            centre.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil
                )
            )
        }
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

    /// What "convert from the listening position" means: the chapter the
    /// listener is in and everything after it, skipping what is already
    /// rendered and what has already been listened to the end. Chapters
    /// *before* the listening position are left alone either way — going
    /// back to one is a choice, and its row converts it.
    func chaptersFromListeningPosition(in book: Book) -> [Chapter] {
        let start = resumeTarget(for: book)
            .flatMap { target in book.chapters.firstIndex { $0.id == target.chapter.id } } ?? 0
        return book.chapters[start...].filter { !$0.isComplete && !isFinished($0) }
    }

    func clearFailure() { loadFailure = nil }
}
