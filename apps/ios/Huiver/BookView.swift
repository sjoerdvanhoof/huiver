import SwiftUI

struct BookView: View {
    let book: Book
    @Environment(AppModel.self) private var model

    /// The book as the library currently has it, so a language change shows up
    /// without leaving the screen.
    private var current: Book {
        model.books.first { $0.id == book.id } ?? book
    }

    private var language: Language { .named(current.languageCode) }

    var body: some View {
        List {
            Section {
                Picker("Language", selection: Binding(
                    get: { language.code },
                    set: { code in
                        Task { await model.setLanguage(.named(code), for: current) }
                    }
                )) {
                    ForEach(Language.all) { option in
                        Text(option.name).tag(option.code)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                if model.canSpeak(current) {
                    Text("Guessed from the book's own text when it was added. Change it if the guess is wrong.")
                } else {
                    // Said plainly rather than hidden behind a disabled button:
                    // Nano will happily read Dutch, just with English
                    // pronunciation, and that is worth knowing before waiting
                    // an hour for a chapter.
                    Text("\(language.name) is one of Chatterbox's 23 languages, but not one Nano can read — Nano is English-only. It will still speak this book, pronouncing the words as though they were English. Reading it properly needs the multilingual model, which is a separate and much larger export.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(current.chapters) { chapter in
                    ChapterRow(book: current, chapter: chapter)
                }
            } header: {
                if let voice = model.selectedVoice {
                    Text("Read by \(voice.name) — \(voice.detail)")
                }
            } footer: {
                Text("Nothing is uploaded. Every chapter is synthesised on this phone.")
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}

private struct ChapterRow: View {
    let book: Book
    let chapter: Chapter
    @Environment(AppModel.self) private var model

    private var isCurrent: Bool { model.narrator?.chapterId == chapter.id }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 30)
            }
            .buttonStyle(.plain)
            .disabled(model.narrator == nil)

            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if chapter.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    private var icon: String {
        guard isCurrent, let narrator = model.narrator else { return "play.circle" }
        switch narrator.state {
        case .speaking: return "pause.circle.fill"
        case .preparing: return "hourglass.circle"
        case .paused: return "play.circle.fill"
        default: return "play.circle"
        }
    }

    private var detail: String {
        // Chatterbox renders at roughly realtime on a phone, so an estimate in
        // minutes of audio is more use than a character count.
        let minutes = max(1, chapter.characters / 900)
        if chapter.isComplete { return "rendered · about \(minutes) min" }
        if chapter.renderedChunks > 0 {
            return "\(chapter.renderedChunks)/\(chapter.chunkCount) chunks · about \(minutes) min"
        }
        return "about \(minutes) min"
    }

    private func toggle() {
        guard let narrator = model.narrator, let voice = model.selectedVoice else { return }
        if isCurrent {
            switch narrator.state {
            case .speaking: narrator.pause()
            case .paused: narrator.resume()
            default: narrator.stop()
            }
            return
        }
        if chapter.isComplete, chapter.renderedVoice == voice.id {
            narrator.replay(book: book, chapter: chapter)
        } else {
            narrator.play(book: book, chapter: chapter, voice: voice, options: model.options)
        }
    }
}
