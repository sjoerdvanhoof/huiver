import SwiftUI

/// A book: cover and details at the top, then its chapters.
///
/// The layout follows `legacy/mobile/app/book/[id].tsx` — large cover beside the
/// title, a Resume/Play button, and a list of chapters each with the podcast
/// download control on the right.
struct BookView: View {
    let book: Book

    @Environment(AppModel.self) private var model
    @Environment(SyncModel.self) private var sync
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showingPlayer = false
    @State private var confirmingDelete = false
    /// A finished export waiting for the share sheet.
    @State private var sharing: ShareItem?

    struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    /// The book as the library currently has it, so language changes and render
    /// progress show up without leaving the screen.
    private var current: Book {
        model.books.first { $0.id == book.id } ?? book
    }

    private var language: Language { .named(current.languageCode) }
    private var renderedCount: Int { current.chapters.filter(\.isComplete).count }

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Palette.Space.lg) {
                    header
                    if !model.canSpeak(current) { languageWarning }
                    chapters
                }
                .padding(.vertical, Palette.Space.lg)
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Language", selection: languageBinding) {
                        ForEach(Language.all) { Text($0.name).tag($0.code) }
                    }
                    // The whole book at once: what the Mac exists for. Only
                    // offered with a Mac to offer it to.
                    if sync.isPaired, renderedCount < current.chapters.count {
                        Button("Convert book on the Mac", systemImage: "desktopcomputer") {
                            Task { await model.requestBookConversionOnMac(current) }
                        }
                    }
                    Divider()
                    Button("Share audiobook", systemImage: "square.and.arrow.up") {
                        Task {
                            if let url = await model.exportAudiobook(current) {
                                sharing = ShareItem(url: url)
                            }
                        }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.narrator?.chapterId != nil {
                MiniPlayer { showingPlayer = true }
                    .background(.bar)
                    .overlay(alignment: .top) { Divider().overlay(theme.colors.border) }
            }
        }
        .sheet(isPresented: $showingPlayer) { PlayerView() }
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
        .sheet(item: $sharing) { item in
            ActivityView(url: item.url)
                .presentationDetents([.medium, .large])
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

    /// Hand a finished export to the system share sheet — AirDrop, Files,
    /// Books, whatever the phone has.
    private struct ActivityView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [url], applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context: Context) {}
    }

    private var languageBinding: Binding<String> {
        .init(
            get: { language.code },
            set: { code in Task { await model.setLanguage(.named(code), for: current) } }
        )
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
                            .frame(width: 140)
                        Text("Preparing audio…")
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
        // What converting the rest will actually cost, from this phone's own
        // measured pace — an answer that used to live nowhere.
        if renderedCount < current.chapters.count,
           let compute = RenderPace.estimate(characters: remainingCharacters) {
            parts.append("\(Format.estimate(compute)) to convert")
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

    private var languageWarning: some View {
        HStack(alignment: .top, spacing: Palette.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            // Said plainly rather than hidden behind a disabled button: Nano
            // will read Dutch, just with English pronunciation, and that is
            // worth knowing before waiting an hour for a chapter.
            Text("\(language.name) is one of Chatterbox's languages, but not one Nano can read — Nano is English-only. It will still speak this book, pronouncing the words as though they were English.")
        }
        .font(.huiverCaption)
        .foregroundStyle(theme.colors.mutedForeground)
        .padding(Palette.Space.md)
        .background(theme.colors.muted, in: .rect(cornerRadius: Palette.Radius.lg))
        .padding(.horizontal, Palette.Space.lg)
    }

    private var chapters: some View {
        // Lazy: public-domain collections run to hundreds of chapters, and an
        // eager stack builds a row — and reads converter and progress state —
        // for every one of them before the first paint.
        LazyVStack(spacing: 0) {
            ForEach(Array(current.chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(
                    book: current, chapter: chapter, number: index + 1,
                    opened: { showingPlayer = true },
                    share: {
                        Task {
                            if let url = await model.exportChapter(chapter, in: current) {
                                sharing = ShareItem(url: url)
                            }
                        }
                    }
                )
                if chapter.id != current.chapters.last?.id {
                    Divider().overlay(theme.colors.border).padding(.leading, Palette.Space.lg)
                }
            }
        }
    }

    /// Carry on where the listener left off: the chapter they were in, at the
    /// second they stopped. Falls back to the first chapter of a book nobody
    /// has opened yet.
    private func resume() {
        guard let narrator = model.narrator, let voice = model.selectedVoice else { return }
        let target = model.resumeTarget(for: current)
            ?? current.chapters.first.map { ($0, 0.0) }
        guard let (chapter, position) = target else { return }

        narrator.listen(
            book: current, chapter: chapter, voice: voice,
            options: model.options, from: position
        )
        showingPlayer = true
    }
}

private struct ChapterRow: View {
    let book: Book
    let chapter: Chapter
    let number: Int
    let opened: () -> Void
    /// Export this chapter and hand it to the share sheet — the sheet lives
    /// on the book screen, so the row only asks.
    let share: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(SyncModel.self) private var sync
    @Environment(\.theme) private var theme

    private var narrator: Narrator? { model.narrator }
    /// The ask outstanding for this chapter, if one was made.
    private var offloaded: AppModel.OffloadState? { model.offloaded[chapter.id] }
    private var isCurrent: Bool { narrator?.chapterId == chapter.id }
    private var isConverting: Bool { model.converter?.isQueued(chapter.id) ?? false }
    private var isFinished: Bool { model.isFinished(chapter) }
    /// Where the listener got to, when they got somewhere and are not done.
    private var listened: Double? { model.position(in: chapter) }

    var body: some View {
        HStack(spacing: Palette.Space.md) {
            Button(action: play) {
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
                .disabled(model.converter == nil)
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
            if chapter.isComplete {
                Button("Share chapter audio", systemImage: "square.and.arrow.up") {
                    share()
                }
                .disabled(model.exporting != nil)
            }
            // Only worth offering with a Mac to offer it to: an ask with
            // nowhere to go would sit in the list for ever looking ignored.
            if sync.isPaired, !chapter.isComplete {
                if offloaded == nil {
                    Button("Convert on the Mac", systemImage: "desktopcomputer") {
                        Task { await model.requestConversionOnMac(chapter: chapter, in: book) }
                    }
                } else {
                    Button("Stop asking the Mac", systemImage: "desktopcomputer.trianglebadge.exclamationmark") {
                        Task { await model.cancelMacRequest(chapter: chapter) }
                    }
                }
            }
        }
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
        // After the queue, so retrying a failed chapter shows it working again
        // rather than still showing the old complaint.
        if chapter.lastRenderError != nil { return .failed }
        return .none
    }

    private var detail: String {
        let estimate = estimatedLength
        // Conversion first: while a chapter is being rendered, that is the
        // thing changing on screen and the thing being waited on.
        if isConverting, let converter = model.converter, converter.active?.chapterId == chapter.id {
            return "converting \(converter.renderedChunks)/\(max(converter.chunkCount, 1)) · \(Format.estimate(estimate))"
        }
        if isConverting { return "queued · \(Format.estimate(estimate))" }
        // Then the Mac, which is work in flight even though nothing is
        // happening on this device.
        if let offloaded { return macDetail(offloaded, estimate: estimate) }
        if let error = chapter.lastRenderError { return error }
        if let listened {
            // Then where the listener is, which beats how much of it has been
            // synthesised — they already know it plays.
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

    /// What the Mac last said about this chapter, in a row's worth of words.
    ///
    /// An ask with no status is not stalled — it is waiting for the two devices
    /// to be in the same room, which may be tonight. Saying so is the whole
    /// point: the alternative is a row that looks like nothing happened.
    private func macDetail(_ state: AppModel.OffloadState, estimate: Double) -> String {
        guard let status = state.status else {
            return "asked of the Mac · \(Format.estimate(estimate))"
        }
        switch status.state {
        case .queued:
            return "waiting on the Mac · \(Format.estimate(estimate))"
        case .rendering:
            return "on the Mac · \(status.renderedChunks)/\(max(status.chunkCount, 1))"
        case .done:
            // The audio comes with the next sync; the Mac has already done its
            // part, and this row is what it looks like in between.
            return "done on the Mac · sync to fetch it"
        case .failed:
            return "the Mac could not render this"
        }
    }

    private func play() {
        guard let narrator, let voice = model.selectedVoice else { return }
        if isCurrent {
            opened()
            return
        }
        // A chapter that was left part-way through picks up there. A finished
        // one starts again from the top — tapping it is how you re-listen.
        let from = listened ?? 0
        narrator.listen(
            book: book, chapter: chapter, voice: voice, options: model.options, from: from
        )
        opened()
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
    /// picked up next time.
    private func toggleRender() {
        guard let converter = model.converter, let voice = model.selectedVoice else { return }
        if isConverting {
            converter.cancel(chapter.id)
        } else if !chapter.isComplete {
            converter.convert(book: book, chapter: chapter, voice: voice, options: model.options)
        }
    }
}
