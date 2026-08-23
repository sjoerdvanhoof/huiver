import SwiftUI
import UniformTypeIdentifiers

/// A book: cover and details at the top, then its chapters — the Mac cut of
/// the iOS BookView, with a "Convert all" in the toolbar because a Mac is the
/// machine you leave rendering a whole book on.
struct BookDetailView: View {
    let book: Book

    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false

    /// The book as the library currently has it, so language changes and render
    /// progress show up without leaving the screen.
    private var current: Book {
        model.books.first { $0.id == book.id } ?? book
    }

    private var language: Language { .named(current.languageCode) }
    private var renderedCount: Int { current.chapters.filter(\.isComplete).count }
    private var incomplete: [Chapter] {
        current.chapters.filter { !$0.isComplete && !(model.converter?.isQueued($0.id) ?? false) }
    }

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Palette.Space.lg) {
                    header
                    if !model.canSpeak(current) { languageWarning }
                    if model.substitutesVoice(for: current) { voiceNote }
                    chapters
                }
                .padding(.vertical, Palette.Space.lg)
            }
        }
        .navigationTitle(current.title)
        // Streaming renders as it plays, so the rows' rings and chunk counts
        // move with the narrator; the library only announces converter work,
        // so what the narrator writes is picked up here.
        .task(id: model.narrator?.renderedChunks) { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    convertAll()
                } label: {
                    Label("Convert book", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(model.converter == nil || incomplete.isEmpty || !model.canSpeak(current))
                .help(model.canSpeak(current)
                    ? "Queue every chapter that has not been rendered yet"
                    : "The model cannot read \(language.name)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Language", selection: languageBinding) {
                        // Only languages the loaded model can read, plus the
                        // book's own tag when it is not one of them — an honest
                        // label the warning below can point at, not an option
                        // whose render would fail on the first chunk.
                        ForEach(pickableLanguages) { Text($0.name).tag($0.code) }
                    }
                    Picker("Voice", selection: voiceBinding) {
                        // "" is "follow the preference"; anything else pins
                        // this book to one narrator regardless of Settings.
                        Text("Preferred voice (\(defaultVoiceName))").tag("")
                        Divider()
                        ForEach(pinnableVoices) { voice in
                            Text(pinLabel(for: voice)).tag(voice.id)
                        }
                    }
                    Divider()
                    Button("Export audiobook…", systemImage: "square.and.arrow.up") {
                        exportAudiobook()
                    }
                    .disabled(renderedCount == 0 || model.exporting != nil)
                    Button("Export chapter files…", systemImage: "square.and.arrow.up.on.square") {
                        exportChapterFiles()
                    }
                    .disabled(renderedCount == 0 || model.exporting != nil)
                    Divider()
                    Button("Delete book", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete this book?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.delete(current)
                    dismiss()
                }
            }
        } message: {
            Text("Its text and any audio rendered for it will be removed.")
        }
        .alert(
            "Could not export",
            isPresented: .init(
                get: { model.exportFailure != nil },
                set: { if !$0 { model.exportFailure = nil } }
            )
        ) {
            Button("OK") { model.exportFailure = nil }
        } message: {
            Text(model.exportFailure ?? "")
        }
    }

    /// The whole book as one chapter-marked `.m4b`, through the save panel.
    private func exportAudiobook() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Audio]
        panel.nameFieldStringValue = AudiobookExporter.filename(current.title) + ".m4b"
        panel.title = "Export audiobook"
        if renderedCount < current.chapters.count {
            panel.message = "Only the \(renderedCount) fully rendered "
                + "chapter\(renderedCount == 1 ? "" : "s") will be included."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let book = current
        Task { await model.exportAudiobook(book, to: url) }
    }

    /// One tagged file per chapter, into a chosen folder.
    private func exportChapterFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.title = "Export chapter files"
        panel.message = renderedCount < current.chapters.count
            ? "One .m4a per fully rendered chapter (\(renderedCount) of \(current.chapters.count))."
            : "One .m4a per chapter."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let book = current
        Task { await model.exportChapterFiles(book, to: url) }
    }

    /// The languages worth offering: what the engine can speak, with the
    /// book's current language kept in the list even when it is unspeakable so
    /// the picker shows the truth rather than a substitute.
    private var pickableLanguages: [Language] {
        var languages = model.engineLanguages
        if !languages.contains(where: { $0.code == language.code }) {
            languages.append(language)
            languages.sort { $0.name < $1.name }
        }
        return languages
    }

    private var languageBinding: Binding<String> {
        .init(
            get: { language.code },
            set: { code in Task { await model.setLanguage(.named(code), for: current) } }
        )
    }

    private var voiceBinding: Binding<String> {
        .init(
            get: { current.voiceId ?? "" },
            set: { id in Task { await model.setVoice(id.isEmpty ? nil : id, for: current) } }
        )
    }

    /// What "follow the preference" resolves to for this book, so the default
    /// row says who would actually read it.
    private var defaultVoiceName: String {
        model.preferredVoice(for: current.languageCode)?.name
            ?? model.selectedVoice?.name ?? "default"
    }

    /// The voices worth pinning: the listener's languages plus this book's
    /// own, with whatever is already pinned kept in the list — the full
    /// eighteen-language roster has no place in a toolbar menu.
    private var pinnableVoices: [Voice] {
        var codes = Set(model.preferredLanguageCodes)
        codes.insert(current.languageCode)
        return model.voices.filter { voice in
            voice.language == nil
                || codes.contains(voice.language!)
                || voice.id == current.voiceId
        }
    }

    /// The voice's accent beside its name, when it differs from the book.
    private func pinLabel(for voice: Voice) -> String {
        guard let code = voice.language, code != current.languageCode else { return voice.name }
        return "\(voice.name) (\(Language.named(code).name))"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Palette.Space.lg) {
            BookCover(
                bookId: current.id,
                title: current.title,
                url: model.coverURL(for: current),
                width: 104,
                radius: Palette.Radius.lg
            )

            VStack(alignment: .leading, spacing: Palette.Space.xs) {
                Text(current.title)
                    .font(.huiverTitle)
                    .foregroundStyle(theme.colors.foreground)
                if let author = current.author {
                    Text(author)
                        .font(.huiverBody)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                Text(summary)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)

                Button(action: resume) {
                    Text(model.resumeTarget(for: current)?.position ?? 0 > 1 ? "Resume" : "Play")
                        .font(.huiverLabel)
                        .foregroundStyle(theme.colors.primaryForeground)
                        .padding(.horizontal, Palette.Space.xl)
                        .padding(.vertical, Palette.Space.sm)
                        .background(theme.colors.primary, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(model.narrator == nil)
                .padding(.top, Palette.Space.xs)

                if let exporting = model.exporting, exporting.bookId == current.id {
                    HStack(spacing: Palette.Space.sm) {
                        ProgressView(value: exporting.fraction)
                            .frame(width: 160)
                        Text("Exporting…")
                            .font(.huiverCaption)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    .padding(.top, Palette.Space.xs)
                }
            }
        }
        .padding(.horizontal, Palette.Space.lg)
    }

    private var summary: String {
        let estimate = Double(current.characters) / Format.assumedCharactersPerSecond
        let finished = current.chapters.filter { model.isFinished($0) }.count
        var parts = ["\(renderedCount)/\(current.chapters.count) rendered"]
        if finished > 0 { parts.append("\(finished) finished") }
        parts.append(Format.estimate(estimate))
        // What converting the rest will actually cost, from this machine's
        // own measured pace — an answer that used to live nowhere.
        if renderedCount < current.chapters.count,
           let compute = RenderPace.estimate(characters: remainingCharacters) {
            parts.append("\(Format.estimate(compute)) to convert")
        }
        if current.languageCode != Language.english.code {
            parts.append(language.name)
        }
        return parts.joined(separator: " · ")
    }

    /// Characters of text not yet rendered, pro-rated for chapters part-done.
    private var remainingCharacters: Int {
        current.chapters.filter { !$0.isComplete }.reduce(0) { total, chapter in
            let done = chapter.chunkCount > 0
                ? Double(chapter.renderedChunks) / Double(chapter.chunkCount) : 0
            return total + Int(Double(chapter.characters) * (1 - done))
        }
    }

    /// Which reader this book will actually get, when it is not the chosen one.
    ///
    /// Said rather than done silently: the voice in Settings is a preference,
    /// and quietly ignoring it for half the library would be worse than the
    /// accent it is avoiding.
    private var voiceNote: some View {
        HStack(alignment: .top, spacing: Palette.Space.sm) {
            Image(systemName: "person.wave.2")
            Text(
                "\(model.voice(for: current)?.name ?? "Another voice") will read this book — "
                    + "a \(language.name) reader. The accent comes from the voice's own "
                    + "recording, so \(model.selectedVoice?.name ?? "the chosen voice") would "
                    + "read \(language.name) with an accent. Pick it explicitly in Voices if "
                    + "that is what you want."
            )
        }
        .font(.huiverCaption)
        .foregroundStyle(theme.colors.mutedForeground)
        .padding(Palette.Space.md)
        .background(theme.colors.muted, in: .rect(cornerRadius: Palette.Radius.lg))
        .padding(.horizontal, Palette.Space.lg)
    }

    private var languageWarning: some View {
        HStack(alignment: .top, spacing: Palette.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(language.name) is not one of the languages this model can read, so its chapters cannot be converted. If the book is actually in another language, change it from the menu above.")
        }
        .font(.huiverCaption)
        .foregroundStyle(theme.colors.mutedForeground)
        .padding(Palette.Space.md)
        .background(theme.colors.muted, in: .rect(cornerRadius: Palette.Radius.lg))
        .padding(.horizontal, Palette.Space.lg)
    }

    private var chapters: some View {
        VStack(spacing: 0) {
            ForEach(Array(current.chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(book: current, chapter: chapter, number: index + 1)
                if chapter.id != current.chapters.last?.id {
                    Divider().overlay(theme.colors.border).padding(.leading, Palette.Space.lg)
                }
            }
        }
    }

    /// Queue everything that has not been rendered, in reading order. The
    /// converter works through it one chapter at a time.
    private func convertAll() {
        guard let converter = model.converter, let voice = model.voice(for: current) else { return }
        for chapter in incomplete {
            converter.convert(book: current, chapter: chapter, voice: voice, options: model.options)
        }
    }

    /// Carry on where the listener left off: the chapter they were in, at the
    /// second they stopped. Falls back to the first chapter of a book nobody
    /// has opened yet.
    private func resume() {
        guard let narrator = model.narrator, let voice = model.voice(for: current) else { return }
        let target = model.resumeTarget(for: current)
            ?? current.chapters.first.map { ($0, 0.0) }
        guard let (chapter, position) = target else { return }

        narrator.listen(
            book: current, chapter: chapter, voice: voice,
            options: model.options, from: position
        )
        navigation.showPlayer()
    }
}

private struct ChapterRow: View {
    let book: Book
    let chapter: Chapter
    let number: Int

    @Environment(AppModel.self) private var model
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    private var narrator: Narrator? { model.narrator }
    private var isCurrent: Bool { narrator?.chapterId == chapter.id }
    private var isConverting: Bool { model.converter?.isQueued(chapter.id) ?? false }
    private var isFinished: Bool { model.isFinished(chapter) }
    /// Playing this chapter is also rendering it: the narrator writes every
    /// chunk it speaks, so a stream in progress is a conversion in progress.
    private var isStreaming: Bool {
        isCurrent && !(narrator?.isFullyRendered ?? true)
    }
    /// Where the listener got to, when they got somewhere and are not done.
    private var listened: Double? { model.position(in: chapter) }
    /// Pressing play or convert on this row would have to synthesize, which
    /// the engine will refuse for a language it cannot read. Audio already on
    /// disk still plays — refusing that too would punish a language change.
    private var cannotRender: Bool {
        !model.canSpeak(book) && !chapter.isComplete
    }

    var body: some View {
        HStack(spacing: Palette.Space.md) {
            playButton

            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Palette.Space.xs) {
                        if isFinished {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.huiverCaption)
                                .foregroundStyle(theme.colors.mutedForeground)
                        }
                        Text("\(number). \(chapter.title)")
                            .font(.huiverBody)
                            .foregroundStyle(titleColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(detail)
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                    if let listened, chapter.chunkCount > 0 {
                        ListenedBar(fraction: listened / max(estimatedLength, 1))
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(narrator == nil)

            ChapterActionButton(state: actionState, action: toggleRender)
                .disabled(model.converter == nil || cannotRender)
        }
        .padding(.horizontal, Palette.Space.lg)
        .padding(.vertical, Palette.Space.md)
        .contextMenu {
            Button(
                isFinished ? "Mark as unfinished" : "Mark as finished",
                systemImage: isFinished ? "arrow.uturn.backward" : "checkmark"
            ) {
                Task { await model.setFinished(!isFinished, chapter: chapter, in: book) }
            }
            if chapter.renderedChunks > 0 {
                Button("Render again", systemImage: "arrow.clockwise") {
                    Task { await model.rerender(chapter: chapter, in: book) }
                }
            }
        }
    }

    /// The one control that unambiguously means "listen to this": a filled
    /// circle with a play glyph, which pauses in place once it is the chapter
    /// being read. The row's text does the same on first click, then opens the
    /// player — this button is what makes that discoverable.
    private var playButton: some View {
        Button {
            if isCurrent {
                narrator?.toggle()
            } else {
                play()
            }
        } label: {
            Image(systemName: isCurrent && narrator?.state == .speaking ? "pause.fill" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isCurrent ? theme.colors.primaryForeground : theme.colors.primary)
                .frame(width: 28, height: 28)
                .background(
                    isCurrent ? AnyShapeStyle(theme.colors.primary) : AnyShapeStyle(theme.colors.muted),
                    in: .circle
                )
        }
        .buttonStyle(.plain)
        .disabled(narrator == nil || (cannotRender && !isCurrent))
        .help(isCurrent
            ? (narrator?.state == .speaking ? "Pause" : "Resume")
            : "Play this chapter")
    }

    private var titleColor: Color {
        if isCurrent { return theme.colors.primary }
        return isFinished ? theme.colors.mutedForeground : theme.colors.foreground
    }

    /// The chapter's length: measured once it is rendered, estimated before.
    private var estimatedLength: Double {
        Double(chapter.characters) / Format.assumedCharactersPerSecond
    }

    private var actionState: ChapterActionButton.State {
        if chapter.isComplete { return .done }
        if isConverting { return .rendering(model.converter?.progress(for: chapter.id)) }
        // A stream is a render: playing an unrendered chapter writes it to
        // disk chunk by chunk, and the ring should say so.
        if isStreaming, let narrator {
            return .rendering(
                narrator.chunkCount > 0
                    ? Double(narrator.renderedChunks) / Double(narrator.chunkCount)
                    : nil
            )
        }
        // After the queue, so retrying a failed chapter shows it working again
        // rather than still showing the old complaint.
        if chapter.lastRenderError != nil { return .failed }
        // Part of it is already on disk: show how much, and offer to carry on
        // from there — resuming picks up after the last written chunk.
        if chapter.renderedChunks > 0, chapter.chunkCount > 0 {
            return .partial(Double(chapter.renderedChunks) / Double(chapter.chunkCount))
        }
        return .none
    }

    private var detail: String {
        let estimate = estimatedLength
        if isConverting, let converter = model.converter, converter.active?.chapterId == chapter.id {
            return "converting \(converter.renderedChunks)/\(max(converter.chunkCount, 1)) · \(Format.estimate(estimate))"
        }
        if isConverting { return "queued · \(Format.estimate(estimate))" }
        if isStreaming, let narrator {
            return "converting \(narrator.renderedChunks)/\(max(narrator.chunkCount, 1)) · \(Format.estimate(estimate))"
        }
        if let error = chapter.lastRenderError { return error }
        if let listened {
            return "\(Format.duration(listened)) in · \(Format.estimate(estimate))"
        }
        if isFinished { return "finished · \(Format.approximate(estimate))" }
        if isCurrent, let seconds = narrator?.renderedSeconds, seconds > 0 {
            // What exists, which is what the scrubber can reach.
            return chapter.isComplete
                ? Format.duration(seconds)
                : "\(Format.duration(seconds)) rendered · \(Format.estimate(estimate))"
        }
        if chapter.isComplete { return Format.approximate(estimate) }
        if chapter.renderedChunks > 0, chapter.chunkCount > 0 {
            return "\(chapter.renderedChunks)/\(chapter.chunkCount) rendered · \(Format.estimate(estimate))"
        }
        return Format.estimate(estimate)
    }

    /// The row's text: the chapter being read opens the player, any other
    /// starts playing — and lands in the player, where the reading is.
    private func open() {
        if isCurrent {
            navigation.showPlayer()
            return
        }
        play()
    }

    private func play() {
        guard let narrator, let voice = model.voice(for: book) else { return }
        // A chapter that was left part-way through picks up there. A finished
        // one starts again from the top — clicking it is how you re-listen.
        let from = listened ?? 0
        narrator.listen(
            book: book, chapter: chapter, voice: voice, options: model.options, from: from
        )
        navigation.showPlayer()
    }

    /// How far through a chapter the listener is.
    ///
    /// Thinner and quieter than the player's `TwoStageBar`, and only about
    /// listening: how much has been rendered is already in the row's detail
    /// line and on the action button.
    private struct ListenedBar: View {
        let fraction: Double

        @Environment(\.theme) private var theme

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    theme.colors.border
                    theme.colors.primary.opacity(0.7)
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
                .clipShape(.capsule)
            }
            .frame(height: 2)
        }
    }

    /// Convert, which means render to disk and nothing else. Pressing it again
    /// stops — a pause, not a discard: the chunks written so far are kept and
    /// picked up next time. When the render in progress is the narrator's own
    /// stream, stopping the conversion is stopping the stream — they are the
    /// same work.
    private func toggleRender() {
        guard let converter = model.converter, let voice = model.voice(for: book) else { return }
        if isConverting {
            converter.cancel(chapter.id)
        } else if isStreaming {
            narrator?.stop()
        } else if !chapter.isComplete {
            converter.convert(book: book, chapter: chapter, voice: voice, options: model.options)
        }
    }
}
