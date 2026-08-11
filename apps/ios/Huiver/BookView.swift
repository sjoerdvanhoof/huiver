import SwiftUI

/// A book: cover and details at the top, then its chapters.
///
/// The layout follows `apps/mobile/app/book/[id].tsx` — large cover beside the
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
            BookCover(bookId: current.id, title: current.title, width: 104, radius: Palette.Radius.lg)

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

                Button(action: playFirstUnfinished) {
                    Text(renderedCount > 0 ? "Resume" : "Play")
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
        return "\(renderedCount)/\(current.chapters.count) rendered · \(Format.estimate(estimate))"
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

    private func playFirstUnfinished() {
        guard let narrator = model.narrator, let voice = model.selectedVoice else { return }
        guard let target = current.chapters.first(where: { !$0.isComplete })
            ?? current.chapters.first
        else { return }
        narrator.play(book: current, chapter: target, voice: voice, options: model.options)
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
    private var isRendering: Bool {
        guard isCurrent, let state = narrator?.state else { return false }
        return state == .speaking || state == .preparing || state == .paused
    }

    var body: some View {
        HStack(spacing: Palette.Space.md) {
            Button(action: play) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(number). \(chapter.title)")
                        .font(.huiverBody)
                        .foregroundStyle(isCurrent ? theme.colors.primary : theme.colors.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(narrator == nil)

            ChapterActionButton(state: actionState, action: toggleRender)
                .disabled(narrator == nil)
        }
        .padding(.horizontal, Palette.Space.lg)
        .padding(.vertical, Palette.Space.md)
    }

    private var actionState: ChapterActionButton.State {
        if isRendering, !chapter.isComplete {
            let total = narrator?.chunkCount ?? 0
            let done = narrator?.renderedChunks ?? 0
            return .rendering(total > 0 ? Double(done) / Double(total) : nil)
        }
        return chapter.isComplete ? .done : .none
    }

    private var detail: String {
        let estimate = Double(chapter.characters) / Format.assumedCharactersPerSecond
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
        if chapter.isComplete, chapter.renderedVoice == voice.id {
            narrator.replay(book: book, chapter: chapter)
        } else {
            narrator.play(book: book, chapter: chapter, voice: voice, options: model.options)
        }
        opened()
    }

    private func toggleRender() {
        guard let narrator, let voice = model.selectedVoice else { return }
        if isRendering {
            narrator.stop()
        } else if !chapter.isComplete {
            narrator.play(book: book, chapter: chapter, voice: voice, options: model.options)
        }
    }
}
