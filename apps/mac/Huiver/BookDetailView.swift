import SwiftUI

/// A book: cover and details at the top, then its chapters — the Mac cut of
/// the iOS BookView, with a "Convert all" in the toolbar because a Mac is the
/// machine you leave rendering a whole book on.
struct BookDetailView: View {
    let book: Book

    @Environment(AppModel.self) private var model
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
                    chapters
                }
                .padding(.vertical, Palette.Space.lg)
            }
        }
        .navigationTitle(current.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    convertAll()
                } label: {
                    Label("Convert all", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(model.converter == nil || incomplete.isEmpty)
                .help("Queue every chapter that has not been rendered yet")
            }
            ToolbarItem(placement: .primaryAction) {
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
        if current.languageCode != Language.english.code {
            parts.append(language.name)
        }
        return parts.joined(separator: " · ")
    }

    private var languageWarning: some View {
        HStack(alignment: .top, spacing: Palette.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(language.name) is not one of the languages this model can read. It will still speak the book, pronouncing the words as though they were English.")
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
        guard let converter = model.converter, let voice = model.selectedVoice else { return }
        for chapter in incomplete {
            converter.convert(book: current, chapter: chapter, voice: voice, options: model.options)
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
    }
}

private struct ChapterRow: View {
    let book: Book
    let chapter: Chapter
    let number: Int

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
        if isConverting, let converter = model.converter, converter.active?.chapterId == chapter.id {
            return "converting \(converter.renderedChunks)/\(max(converter.chunkCount, 1)) · \(Format.estimate(estimate))"
        }
        if isConverting { return "queued · \(Format.estimate(estimate))" }
        if let error = chapter.lastRenderError { return error }
        if let listened {
            return "\(Format.duration(listened)) in · \(Format.estimate(estimate))"
        }
        if isFinished { return "finished · \(Format.approximate(estimate))" }
        if chapter.isComplete { return Format.approximate(estimate) }
        if chapter.renderedChunks > 0, chapter.chunkCount > 0 {
            return "\(chapter.renderedChunks)/\(chapter.chunkCount) rendered · \(Format.estimate(estimate))"
        }
        return Format.estimate(estimate)
    }

    private func play() {
        guard let narrator, let voice = model.selectedVoice else { return }
        if isCurrent {
            narrator.toggle()
            return
        }
        // A chapter that was left part-way through picks up there. A finished
        // one starts again from the top — clicking it is how you re-listen.
        let from = listened ?? 0
        if chapter.isComplete, chapter.renderedVoice == voice.id {
            narrator.replay(book: book, chapter: chapter, from: from)
        } else {
            narrator.play(
                book: book, chapter: chapter, voice: voice, options: model.options, from: from
            )
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
