import AppKit
import CryptoKit
import Foundation
import Observation
import UserNotifications

/// Everything the screens share: the library, the engine, the voice list.
///
/// The Mac twin of the iOS AppModel. The engine is loaded lazily and its
/// failure is kept rather than thrown, so a Mac whose models have not been
/// exported yet still opens and explains itself instead of crashing on launch.
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
    /// Extraction in progress — unzip, XML, a regex over the whole text — so
    /// the shelf can say so instead of the window freezing.
    private(set) var isImporting = false
    /// Set by File ▸ Open; the library screen watches it and opens its panel.
    var wantsImport = false
    private(set) var isLoading = true
    private(set) var bytesOnDisk: Int64 = 0

    /// Which processor Core ML gave each model, shown in Settings.
    private(set) var placement: [String: String] = [:]
    /// Languages the loaded models can actually read.
    private(set) var engineLanguages: [Language] = [.english]
    private var speechEngine: ChatterboxEngine?

    /// Derived, local-only pronunciation reports keyed by stable content id.
    private(set) var preflightReports: [String: PreflightReport] = [:]
    private(set) var analyzingPronunciation: Set<String> = []
    private(set) var languagePacks: [LanguagePackDescriptor] = []
    private var languagePackManager: LanguagePackManager?
    var languagePackFailure: String?

    /// The one checkpoint this app runs. Nano stayed on the phone.
    let engineName = "Chatterbox Multilingual 500M"
    /// What the engine is doing while it loads, for the preparing state.
    private(set) var preparing: ChatterboxEngine.LoadProgress?
    private(set) var preparingSince: Date?
    /// True on the run that actually compiles the models, which is the slow one
    /// worth explaining. Set once the first load finishes.
    var hasPreparedBefore: Bool {
        UserDefaults.standard.bool(forKey: "preparedOnce")
    }
    /// Every chapter's listening state, for the lists that draw it. Refreshed
    /// from the store rather than read through it, so a view body never has to
    /// await an actor.
    private(set) var progress: [String: ChapterProgress] = [:]

    /// The multilingual model's numbers from the start: it filters in a
    /// different order and uses a relative floor where Nano used top-k.
    /// Remembered across launches — a slider is a preference, not a session.
    var options = SamplingOptions.multilingual {
        didSet {
            guard let data = try? JSONEncoder().encode(options) else { return }
            UserDefaults.standard.set(data, forKey: "samplingOptions")
        }
    }

    /// Stop reading after a while. Owned here so it outlives any one screen.
    let sleepTimer = SleepTimer()

    /// Delete a finished chapter's audio after a week. On by default — a Mac
    /// has more disk than a phone, but a shelf of finished books still adds up.
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

    /// The languages this listener actually reads books in. Everything else's
    /// voices stay out of the pickers — the roster ships a reader for each of
    /// eighteen languages, and a shelf of English and Dutch books has no use
    /// for the Greek one. Chosen at onboarding, extended from Settings, and
    /// extended automatically when a book arrives in something new.
    private(set) var preferredLanguageCodes: [String] {
        didSet { UserDefaults.standard.set(preferredLanguageCodes, forKey: "preferredLanguages") }
    }

    /// Which voice reads each language, by language code. Its own map rather
    /// than one selection: switching between an English and a Dutch book
    /// should not need the narrator re-picked every time.
    private(set) var preferredVoiceIds: [String: String] {
        didSet { UserDefaults.standard.set(preferredVoiceIds, forKey: "preferredVoices") }
    }

    /// Books that arrived in a language nobody has picked a voice for yet.
    /// The window shows one sheet per language and works through the queue.
    var pendingLanguagePrompts: [NewLanguagePrompt] = []

    struct NewLanguagePrompt: Identifiable {
        let language: Language
        let bookTitle: String
        var id: String { language.code }
    }

    var preferredLanguages: [Language] { preferredLanguageCodes.map(Language.named) }

    /// What the language pickers offer: the engine's own list once it has
    /// loaded, and Chatterbox's known-good subset while it is still compiling —
    /// onboarding runs before the engine finishes.
    var selectableLanguages: [Language] {
        if engineLanguages.count > 1 { return engineLanguages }
        let unreadable: Set<String> = ["zh", "ja", "he", "ko", "ru"]
        return Language.all.filter { !unreadable.contains($0.code) }
    }

    func setPreferredLanguages(_ codes: [String]) {
        preferredLanguageCodes = Self.languageOrder(codes)
    }

    func addPreferredLanguage(_ code: String) {
        guard !preferredLanguageCodes.contains(code) else { return }
        preferredLanguageCodes = Self.languageOrder(preferredLanguageCodes + [code])
    }

    /// The last language stays: an empty list would leave every picker blank.
    func removePreferredLanguage(_ code: String) {
        guard preferredLanguageCodes.count > 1 else { return }
        preferredLanguageCodes.removeAll { $0 == code }
    }

    /// `Language.all` is in name order; keeping the preference list in the
    /// same order keeps every screen's sections in the same order.
    private static func languageOrder(_ codes: some Collection<String>) -> [String] {
        let wanted = Set(codes)
        return Language.all.map(\.code).filter { wanted.contains($0) }
    }

    /// Make this voice the reader for one language, and make sure that
    /// language is on the list — picking a voice for it is wanting it.
    func setPreferredVoice(_ voiceId: String, for languageCode: String) {
        preferredVoiceIds[languageCode] = voiceId
        addPreferredLanguage(languageCode)
    }

    /// A voice picked by hand: the app-wide selection, and the preferred
    /// reader for the language its clip was recorded in.
    func selectVoice(_ voice: Voice) {
        selectedVoiceId = voice.id
        if let code = voice.language { setPreferredVoice(voice.id, for: code) }
    }

    /// The voice that reads books in this language: the one chosen for it,
    /// else the app-wide voice when its accent fits, else the first reader
    /// recorded in the language.
    func preferredVoice(for languageCode: String) -> Voice? {
        if let id = preferredVoiceIds[languageCode],
           let voice = voices.first(where: { $0.id == id }) {
            return voice
        }
        if let selected = selectedVoice,
           selected.language == nil || selected.language == languageCode {
            return selected
        }
        return voices.first { $0.language == languageCode }
    }

    /// Which voice should read this book.
    ///
    /// The chosen voice, unless the book is in a language that voice was not
    /// recorded in and there *is* a reader for it — then that reader, because
    /// the accent comes from the reference clip rather than from the text. An
    /// English clip reading Dutch is an English speaker reading Dutch, which is
    /// the single most audible thing about the multilingual model.
    ///
    /// A preference rather than a rule: the chosen voice wins whenever it can,
    /// and picking a language nobody was recorded in still reads the book rather
    /// than refusing.
    func voice(for book: Book) -> Voice? {
        // A voice pinned to the book beats everything — pinning is the
        // listener saying exactly this.
        if let pinned = book.voiceId, let voice = voices.first(where: { $0.id == pinned }) {
            return voice
        }
        return preferredVoice(for: book.languageCode) ?? selectedVoice
    }

    /// Whether `voice(for:)` would override the chosen voice, so a screen can
    /// say so rather than surprising the listener. Neither a pinned voice nor
    /// a per-language choice is a substitution — both are the listener's own
    /// instruction.
    func substitutesVoice(for book: Book) -> Bool {
        guard book.voiceId == nil,
              preferredVoiceIds[book.languageCode] == nil,
              let selected = selectedVoice, let chosen = voice(for: book)
        else { return false }
        return chosen.id != selected.id
    }

    /// Pin a voice to one book, or nil to follow the app-wide selection.
    func setVoice(_ voiceId: String?, for book: Book) async {
        guard let library else { return }
        try? await library.setVoice(voiceId, for: book.id)
        books = await library.all()
    }

    private(set) var library: Library?
    private(set) var progressStore: ProgressStore?
    /// Turns a recording into a voice, when the export shipped `MTLVoiceCloner`.
    private(set) var cloner: VoiceCloner?
    /// Where voices cloned on this Mac live. The bundle's pack is read-only, so
    /// a recorded voice goes beside the library instead.
    private(set) var recordedVoices: URL?

    var canCloneVoices: Bool { cloner != nil }

    /// Asks from the phone whose book had not arrived yet when they were made.
    ///
    /// Kept in memory only, and deliberately: the phone re-sends its whole list
    /// in every manifest, so the worst a forgotten one costs is a round trip.
    /// Writing them down would mean a second queue to keep honest.
    private var deferredRequests: [ConvertRequest] = []

    init() {
        selectedVoiceId = UserDefaults.standard.string(forKey: "voice") ?? "mtl_default"
        preferredLanguageCodes = UserDefaults.standard.stringArray(forKey: "preferredLanguages") ?? []
        preferredVoiceIds =
            UserDefaults.standard.dictionary(forKey: "preferredVoices") as? [String: String] ?? [:]
        // Observers do not fire in init, so this neither re-saves what it read
        // nor loses the preset when nothing was stored.
        if let data = UserDefaults.standard.data(forKey: "samplingOptions"),
           let stored = try? JSONDecoder().decode(SamplingOptions.self, from: data) {
            options = stored
        }
    }

    /// The models and voices are bundled with the app; the library lives in
    /// Application Support rather than Documents — on the Mac, Documents is the
    /// user's own space, and a folder of app-managed audio does not belong in it.
    /// Guards `load()` against running twice: ⌘N gives every new window a
    /// `.task` that calls it, and a second pass would re-load a gigabyte of
    /// models and orphan the narrator mid-sentence.
    private var loadStarted = false

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        isLoading = true
        defer { isLoading = false }

        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            loadFailure = "No Application Support directory"
            return
        }
        let root = support.appendingPathComponent("Huiver", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let library = try Library(root: root)
            self.library = library
            await PronunciationStore.shared.configure(root: root)
            await PreflightStore.shared.configure(root: root)
            let configuredKeys = Bundle.main.object(forInfoDictionaryKey: "LanguagePackPublicKeys")
                as? [String: String] ?? [:]
            let keys: [String: Data] = configuredKeys.compactMapValues { encoded in
                Data(base64Encoded: encoded)
            }
            languagePackManager = try LanguagePackManager(root: root, trustedPublicKeys: keys)
            languagePacks = try await languagePackManager?.installed() ?? []
            books = await library.all()
            bytesOnDisk = await library.bytesOnDisk()
        } catch {
            loadFailure = "Could not open the library: \(error.localizedDescription)"
            return
        }

        let progressStore = ProgressStore(root: root)
        self.progressStore = progressStore
        progress = await progressStore.chapters()
        await progressStore.onChange { [weak self] in
            Task { @MainActor in await self?.refreshProgress() }
        }

        guard let resources = Bundle.main.resourceURL else {
            loadFailure = "No resources in the app bundle"
            return
        }

        recordedVoices = root.appendingPathComponent("Voices", isDirectory: true)
        do {
            voices = try VoicePack.load(
                from: resources.appendingPathComponent("Voices"), plus: recordedVoices
            )
        } catch {
            loadFailure = error.localizedDescription
            return
        }

        // A library that predates the language list gets one seeded from what
        // it already holds — the languages on the shelf plus the chosen
        // voice's own — rather than being asked to start over.
        if UserDefaults.standard.stringArray(forKey: "preferredLanguages") == nil {
            var codes = Set(books.map(\.languageCode))
            codes.insert(Language.english.code)
            if let accent = selectedVoice?.language { codes.insert(accent) }
            preferredLanguageCodes = Self.languageOrder(codes)
        }

        // Cloning is a separate model from the four the engine loads, and a
        // separate failure: a Mac that cannot clone should still read books.
        let modelDirectory = resources.appendingPathComponent("Models")
        if VoiceCloner.isAvailable(in: modelDirectory) {
            cloner = try? await VoiceCloner(models: modelDirectory)
        }

        preparingSince = Date()
        do {
            let engine = try await ChatterboxEngine.load(
                models: .init(directory: resources.appendingPathComponent("Models"))
            ) { [weak self] progress in
                Task { @MainActor in self?.preparing = progress }
            }
            // Multilingual only. A Nano export in the bundle is a packaging
            // mistake, and reading books with the wrong sampling defaults
            // would be worse than saying so.
            guard engine.variant == .multilingual else {
                throw NSError(
                    domain: "Huiver", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The bundled models are not the multilingual checkpoint. "
                            + "Export them with bun run mac:models && bun run mac:install."
                    ]
                )
            }
            speechEngine = engine
            let narrator = Narrator(engine: engine, library: library!, progress: progressStore)
            self.narrator = narrator
            narrator.renderPassDidEnd = { [weak self] in self?.trimEngineMemoryIfIdle() }
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
        for book in books { schedulePronunciationAnalysis(for: book) }
    }

    func importLanguagePack(from url: URL) async {
        guard let languagePackManager else { return }
        do {
            let descriptor = try await languagePackManager.install(archive: Data(contentsOf: url))
            languagePacks = try await languagePackManager.installed()
            languagePackFailure = nil
            for book in books where book.languageCode == descriptor.languageCode {
                schedulePronunciationAnalysis(for: book)
            }
        } catch {
            languagePackFailure = error.localizedDescription
        }
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
        // A file handed over by the open panel or a drop lives outside the
        // sandbox until it is read, and the scope has to be given back after.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        isImporting = true
        defer { isImporting = false }
        do {
            let filename = url.lastPathComponent
            // Extraction — unzip, XML, HTML stripping, a regex over the whole
            // text — off the main actor, where a large EPUB froze the window.
            let (data, extracted) = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return (data, try Extract.book(from: data, filename: filename))
            }.value
            let book = try await library.add(extracted, source: (data: data, filename: filename))
            books = await library.all()
            schedulePronunciationAnalysis(for: book)
            // A language nobody has picked a voice for yet: ask, rather than
            // silently handing the book to whichever reader falls out of the
            // fallback. One prompt per language, however many books arrive.
            if !preferredLanguageCodes.contains(book.languageCode),
               !pendingLanguagePrompts.contains(where: { $0.id == book.languageCode }) {
                pendingLanguagePrompts.append(
                    NewLanguagePrompt(
                        language: .named(book.languageCode), bookTitle: book.title
                    )
                )
            }
        } catch {
            importFailure = error.localizedDescription
        }
    }

    /// The last chance to write anything down. `applicationShouldTerminate`
    /// holds the quit open until this returns — the debounced library save and
    /// the position ticker's lazy write are both exactly what ⌘Q would lose.
    func shutdown() async {
        await narrator?.checkpointNow()
        await progressStore?.flush()
        await library?.flushNow()
    }

    /// Where a book's cover image is, if the EPUB had one.
    func coverURL(for book: Book) -> URL? {
        library?.coverURL(book)
    }

    func setLanguage(_ language: Language, for book: Book) async {
        guard let library else { return }
        try? await library.setLanguage(language, for: book.id)
        books = await library.all()
        if let fresh = books.first(where: { $0.id == book.id }) {
            schedulePronunciationAnalysis(for: fresh)
        }
    }

    func setLocale(_ identifier: String?, for book: Book) async {
        guard let library else { return }
        try? await library.setLocale(identifier, for: book.id)
        books = await library.all()
        if let fresh = books.first(where: { $0.id == book.id }) {
            schedulePronunciationAnalysis(for: fresh)
        }
    }

    func preflight(for book: Book) -> PreflightReport? {
        preflightReports[book.contentId ?? book.derivedContentId]
    }

    func schedulePronunciationAnalysis(for book: Book) {
        guard book.languageCode == "en" || book.languageCode == "nl" else { return }
        let contentId = book.contentId ?? book.derivedContentId
        guard !analyzingPronunciation.contains(contentId) else { return }
        analyzingPronunciation.insert(contentId)
        Task { [weak self] in
            let report = await TextPreprocessing.analyze(book)
            await PreflightStore.shared.store(report, contentId: contentId)
            guard let self else { return }
            self.preflightReports[contentId] = report
            self.analyzingPronunciation.remove(contentId)
        }
    }

    func savePronunciation(
        candidate: PronunciationCandidate, replacement: String, spellLetters: Bool,
        global: Bool, in book: Book
    ) async throws {
        guard let match = candidate.surfaceForms.first else { return }
        let value = PronunciationOverride(
            languageCode: book.languageCode,
            bookContentId: global ? nil : (book.contentId ?? book.derivedContentId),
            matchText: match,
            replacement: replacement,
            mode: spellLetters ? .spellLetters : .sayAs,
            matchCase: candidate.category == .acronym ? .sensitive : .insensitive,
            updatedByDevice: Host.current().localizedName ?? "mac"
        )
        try await PronunciationStore.shared.upsert(value)
        schedulePronunciationAnalysis(for: book)
    }

    func ignorePronunciation(_ candidate: PronunciationCandidate, in book: Book) async {
        let contentId = book.contentId ?? book.derivedContentId
        try? await PronunciationStore.shared.ignore(
            PronunciationDecision(
                contentId: contentId, candidateId: candidate.id,
                updatedByDevice: Host.current().localizedName ?? "mac"
            )
        )
        schedulePronunciationAnalysis(for: book)
    }

    func markPreflightReviewed(_ report: PreflightReport, book: Book) async {
        try? await PronunciationStore.shared.markReviewed(
            contentId: book.contentId ?? book.derivedContentId,
            fingerprint: report.fingerprint
        )
    }

    func pronunciationPreview(
        _ text: String, replacement: PronunciationOverride?, book: Book
    ) async throws -> URL {
        guard let speechEngine, let voice = voice(for: book) else {
            throw NSError(domain: "Huiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "The narrator is not ready."])
        }
        let chunk = Chunker.Chunk(text: text, beginsMidSentence: false, endsMidSentence: false)
        let contentId = book.contentId ?? book.derivedContentId
        var overrides = await PronunciationStore.shared.effective(
            language: book.languageCode, contentId: contentId
        )
        if let replacement { overrides.insert(replacement, at: 0) }
        let context = ProcessingContext(
            language: .named(book.languageCode), locale: LocaleProfile(book.spokenLocaleIdentifier),
            contentId: contentId, overrides: overrides
        )
        let processed = await LanguageProcessorRegistry.processor(for: book.languageCode)
            .process(chunk: chunk, context: context)
        let samples = try await speechEngine.speak(
            processed.spokenText, voice: voice, options: options,
            language: .named(book.languageCode)
        )
        let key = ProcessedChunk(
            displayText: text, spokenText: processed.spokenText,
            substitutions: processed.substitutions, fingerprint: processed.fingerprint
        ).fingerprint
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narcisse-pronunciation-\(key.prefix(16)).wav")
        try WavFile.data(from: samples).write(to: url, options: .atomic)
        return url
    }

    /// Can the engine read this book, or will it mispronounce it?
    func canSpeak(_ book: Book) -> Bool {
        engineLanguages.contains { $0.code == book.languageCode }
    }

#if DEBUG
    /// The Pronunciation Lab's book-less processing path: same processor,
    /// same global corrections, a synthetic content id so no book-scoped
    /// override can leak in.
    func devProcess(_ text: String, languageCode: String, localeIdentifier: String) async -> ProcessedChunk {
        let overrides = await PronunciationStore.shared.effective(
            language: languageCode, contentId: "dev-lab"
        )
        let context = ProcessingContext(
            language: .named(languageCode), locale: LocaleProfile(localeIdentifier),
            contentId: "dev-lab", overrides: overrides
        )
        let chunk = Chunker.Chunk(text: text, beginsMidSentence: false, endsMidSentence: false)
        return await LanguageProcessorRegistry.processor(for: languageCode)
            .process(chunk: chunk, context: context)
    }

    /// Speak an already-processed spoken form through the engine and hand back
    /// a temporary wav, so the lab can A/B what a rule actually sounds like.
    func devSpeak(_ spokenText: String, languageCode: String) async throws -> URL {
        guard let speechEngine, let voice = preferredVoice(for: languageCode) ?? selectedVoice else {
            throw NSError(domain: "Huiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "The narrator is not ready."])
        }
        let samples = try await speechEngine.speak(
            spokenText, voice: voice, options: options, language: .named(languageCode)
        )
        let stamp = SHA256.hash(data: Data(spokenText.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narcisse-devlab-\(stamp).wav")
        try WavFile.data(from: samples).write(to: url, options: .atomic)
        return url
    }
#endif

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
        guard let library, let converter, let voice = voice(for: book) else { return }
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
    func setFinished(_ finished: Bool, chapter: Chapter, in book: Book) async {
        await progressStore?.setFinished(finished, chapterId: chapter.id, bookId: book.id)
        await progressStore?.flush()
        await refreshProgress()
    }

    func refresh() async {
        guard let library else { return }
        books = await library.all()
        await refreshProgress()
        // The converter announces every queue change through here, so the
        // queue draining is one of the two moments synthesis can go quiet.
        trimEngineMemoryIfIdle()
        updateConversionSurface()
    }

    /// The disk total is a full walk of the audio tree, so it is refreshed
    /// when the Settings pane asks — not on the converter's every chunk, which
    /// used to stat thousands of files a minute during a render.
    func refreshStorage() async {
        guard let library else { return }
        bytesOnDisk = await library.bytesOnDisk()
    }

    /// What the Dock and Notification Centre say about the queue: a badge
    /// while chapters wait, and a notification when the last one lands —
    /// multi-hour jobs deserve both.
    private var wasConverting = false

    private func updateConversionSurface() {
        let queued = (converter?.queue.count ?? 0) + (converter?.active != nil ? 1 : 0)
        NSApp.dockTile.badgeLabel = queued > 0 ? "\(queued)" : nil

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

    /// Give MLX's buffer pool back once nothing is synthesizing.
    ///
    /// The pool exists to be reused within a render; between renders it is
    /// gigabytes of stale transients that Activity Monitor charges to the app.
    /// Playing already-rendered audio never touches MLX, so a fully rendered
    /// chapter still counts as idle here — only a stream mid-write, or a
    /// converter job, is work worth keeping the pool warm for.
    func trimEngineMemoryIfIdle() {
        if let converter, converter.isBusy { return }
        if let narrator, narrator.chapterId != nil, !narrator.isFullyRendered { return }
        EngineMemory.trim()
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

    // MARK: - Export

    /// The export in flight, for the book screen's progress bar. One at a
    /// time: two AAC encodes at once would fight over the same encoder for no
    /// net gain.
    private(set) var exporting: (bookId: String, fraction: Double)?
    var exportFailure: String?

    /// The book's fully rendered chapters as one chapter-marked audiobook.
    func exportAudiobook(_ book: Book, to destination: URL) async {
        guard let library, exporting == nil else { return }
        exporting = (book.id, 0)
        defer { exporting = nil }

        let chapters = exportableChapters(of: book, in: library)
        let metadata = AudiobookExporter.BookMetadata(
            title: book.title,
            author: book.author,
            cover: coverURL(for: book).flatMap { try? Data(contentsOf: $0) }
        )
        // Percent steps only: the writer reports every buffer, and a main-actor
        // hop per 1.3 s of audio adds up over a ten-hour book.
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
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            exportFailure = error.localizedDescription
        }
    }

    /// The book's fully rendered chapters as numbered, tagged files in a
    /// folder — for players that want tracks rather than one audiobook.
    func exportChapterFiles(_ book: Book, to folder: URL) async {
        guard let library, exporting == nil else { return }
        exporting = (book.id, 0)
        defer { exporting = nil }

        let chapters = exportableChapters(of: book, in: library)
        let metadata = AudiobookExporter.BookMetadata(
            title: book.title,
            author: book.author,
            cover: coverURL(for: book).flatMap { try? Data(contentsOf: $0) }
        )
        do {
            var lastError: Error?
            for (index, chapter) in chapters.enumerated() {
                let name = AudiobookExporter.filename(chapter.title, number: index + 1)
                let destination = folder.appendingPathComponent("\(name).m4a")
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try AudiobookExporter.writeChapterM4A(
                            chunkURLs: chapter.chunkURLs,
                            title: chapter.title,
                            track: (index + 1, chapters.count),
                            metadata: metadata,
                            to: destination
                        )
                    }.value
                } catch {
                    lastError = error
                }
                exporting = (book.id, Double(index + 1) / Double(max(chapters.count, 1)))
            }
            if let lastError { throw lastError }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            exportFailure = error.localizedDescription
        }
    }

    /// Fully rendered chapters, with their chunk files in playback order.
    /// Export never includes a partial chapter: a book that stops mid-sentence
    /// reads as broken, where a missing chapter reads as unfinished work.
    private func exportableChapters(
        of book: Book, in library: Library
    ) -> [AudiobookExporter.Chapter] {
        book.chapters.filter(\.isComplete).map { chapter in
            AudiobookExporter.Chapter(
                title: chapter.title,
                chunkURLs: (0..<chapter.renderedChunks).map {
                    library.chunkURL(book: book.id, chapter: chapter.id, index: $0)
                }
            )
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

    // MARK: - Rendering for the phone

    /// Take on what the phone has asked for, and say what became of each ask.
    ///
    /// Called while the manifests are still being exchanged, which is before
    /// this session's books have arrived — so an ask for a book the Mac has
    /// never seen is held rather than refused, and placed at the end of the
    /// session by `placeDeferredRequests()`.
    func acceptConvertRequests(_ requests: [ConvertRequest]) -> [SyncMessage.JobStatus] {
        var statuses: [SyncMessage.JobStatus] = []
        var deferred: [ConvertRequest] = []
        for request in requests {
            switch place(request) {
            case .placed(let status):
                statuses.append(status)
            case .bookNotHereYet:
                deferred.append(request)
                statuses.append(
                    SyncMessage.JobStatus(
                        requestId: request.requestId,
                        state: .queued,
                        renderedChunks: 0,
                        chunkCount: 0
                    )
                )
            }
        }
        deferredRequests = deferred
        return statuses
    }

    /// Place the asks that arrived before their book did. Called once the
    /// session's transfers are finished and the library has caught up.
    func placeDeferredRequests() {
        let pending = deferredRequests
        deferredRequests = []
        for request in pending { _ = place(request) }
    }

    private enum Placement {
        case placed(SyncMessage.JobStatus)
        case bookNotHereYet
    }

    /// One ask, against the library and the queue as they are now.
    private func place(_ request: ConvertRequest) -> Placement {
        guard let book = books.first(where: { $0.contentId == request.contentId }),
              book.chapters.indices.contains(request.chapterIndex)
        else { return .bookNotHereYet }
        let chapter = book.chapters[request.chapterIndex]

        func status(_ state: SyncMessage.JobStatus.State, rendered: Int) -> Placement {
            .placed(
                SyncMessage.JobStatus(
                    requestId: request.requestId,
                    state: state,
                    renderedChunks: rendered,
                    chunkCount: chapter.chunkCount
                )
            )
        }

        if chapter.isComplete {
            // Already done, in the voice that was asked for: the audio goes
            // over in this same session's diff.
            if chapter.renderedVoice == request.voiceId {
                return status(.done, rendered: chapter.renderedChunks)
            }
            // Done, but by another narrator. Re-rendering would throw away
            // audio this Mac's own listener may be part-way through, which is
            // the listener's call and not sync's — the same rule the diff
            // follows when it declines to take audio in a voice it did not ask
            // for. Say so rather than silently doing nothing.
            return status(.failed, rendered: chapter.renderedChunks)
        }

        guard let converter, let voice = voices.first(where: { $0.id == request.voiceId }) else {
            // Either the engine never loaded, or this is a voice the Mac does
            // not have. Both are things the phone should hear about.
            return status(.failed, rendered: chapter.renderedChunks)
        }

        if converter.isQueued(chapter.id) {
            let isActive = converter.active?.chapterId == chapter.id
            return status(
                isActive ? .rendering : .queued,
                rendered: isActive ? converter.renderedChunks : chapter.renderedChunks
            )
        }

        converter.convert(book: book, chapter: chapter, voice: voice, options: options)
        return status(.queued, rendered: chapter.renderedChunks)
    }

    // MARK: - Cloning a voice

    /// Turn a recording into a voice and add it to the roster.
    ///
    /// The recording itself is not kept. What is written is the five tensors a
    /// voice consists of, none of which can be turned back into audio — the same
    /// bargain the shipped voices make, and worth keeping when the recording is
    /// the listener's own.
    func cloneVoice(from recording: [Float], name: String, language: Language) async throws -> Voice {
        guard let cloner, let recordedVoices else { throw VoiceCloner.CloneError.unavailable }

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

        let voice = try await cloner.clone(
            recording,
            id: id,
            name: name.isEmpty ? "My voice" : name,
            detail: "recorded in \(language.name) on this Mac",
            persona: "Your own voice, cloned from a short recording. It reads every "
                + "language the model knows, with your accent.",
            language: language.code
        )
        try VoicePack.write(voice, to: recordedVoices)
        voices = try VoicePack.load(
            from: Bundle.main.resourceURL!.appendingPathComponent("Voices"),
            plus: recordedVoices
        )
        // Recording yourself in a language is picking yourself for it.
        selectVoice(voice)
        return voice
    }

    /// Clone the recording into a throwaway voice and read a short passage
    /// with it, so a trim can be judged by ear before anything is saved.
    /// Neither the voice nor the audio is kept.
    func previewClonedSpeech(
        from recording: [Float],
        text: String,
        language: Language,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [Float] {
        guard let cloner, let engine = speechEngine else {
            throw VoiceCloner.CloneError.unavailable
        }
        let voice = try await cloner.clone(
            recording,
            id: "preview",
            name: "Preview",
            detail: "trim preview, never saved",
            language: language.code
        )
        return try await engine.speak(
            text, voice: voice, language: language, cancelled: cancelled
        )
    }

    /// Whether this voice was cloned here, and can therefore be deleted.
    func isRecorded(_ voice: Voice) -> Bool {
        guard let recordedVoices else { return false }
        return FileManager.default.fileExists(
            atPath: recordedVoices.appendingPathComponent("\(voice.id).voice").path
        )
    }

    func deleteVoice(_ voice: Voice) {
        guard let recordedVoices, isRecorded(voice) else { return }
        try? VoicePack.remove(id: voice.id, from: recordedVoices)
        voices = (try? VoicePack.load(
            from: Bundle.main.resourceURL!.appendingPathComponent("Voices"),
            plus: recordedVoices
        )) ?? voices
        if selectedVoiceId == voice.id { selectedVoiceId = voices.first?.id ?? "mtl_default" }
        // Any language it was reading falls back to the resolution order
        // rather than keeping a preference that points at nothing.
        for (code, id) in preferredVoiceIds where id == voice.id {
            preferredVoiceIds[code] = nil
        }
    }

    func clearFailure() { loadFailure = nil }
}
