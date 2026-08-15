import SwiftUI

/// A book: cover and details at the top, then its chapters.
///
/// The layout follows `legacy/mobile/app/book/[id].tsx` — large cover beside the
/// title, a Resume/Play button, and a list of chapters each with the podcast
/// download control on the right.
struct BookView: View {
    let book: Book

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showingPlayer = false
    @State private var confirmingDelete = false

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
        return parts.joined(separator: " · ")
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
        VStack(spacing: 0) {
            ForEach(Array(current.chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(book: current, chapter: chapter, number: index + 1) {
                    showingPlayer = true
                }
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

        if chapter.isComplete, chapter.renderedVoice == voice.id {
            narrator.replay(book: current, chapter: chapter, from: position)
        } else {
            narrator.play(
                book: current, chapter: chapter, voice: voice,
                options: model.options, from: position
            )
        }
        showingPlayer = true
    }
}

private struct ChapterRow: View {
    let book: Book
    let chapter: Chapter
    let number: Int
    let opened: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var narrator: Narrator? { model.narrator }
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

    private func play() {
        guard let narrator, let voice = model.selectedVoice else { return }
        if isCurrent {
            opened()
            return
        }
        // A chapter that was left part-way through picks up there. A finished
        // one starts again from the top — tapping it is how you re-listen.
        let from = listened ?? 0
        if chapter.isComplete, chapter.renderedVoice == voice.id {
            narrator.replay(book: book, chapter: chapter, from: from)
        } else {
            narrator.play(
                book: book, chapter: chapter, voice: voice, options: model.options, from: from
            )
        }
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
