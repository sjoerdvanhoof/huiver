import SwiftUI

/// Everything waiting to be converted.
///
/// The queue has always existed and survived relaunches; until now the only
/// sign of it was a count in Settings. This is that list, with the one thing a
/// list of pending work needs — a way to take something out of it.
struct QueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var converter: Converter? { model.converter }

    /// The job being worked on, then everything behind it. The active job is
    /// the head of the queue rather than a separate thing, so it is shown
    /// first and not twice.
    private var waiting: [Converter.Job] {
        guard let converter else { return [] }
        return converter.queue.filter { $0.chapterId != converter.active?.chapterId }
    }

    /// Work this phone has handed to the Mac. It belongs on this screen for the
    /// same reason the local queue does — it is a chapter that is coming — even
    /// though nothing on this device is doing it.
    private var asked: [Asked] {
        model.books.flatMap { book in
            book.chapters.compactMap { chapter in
                model.offloaded[chapter.id].map {
                    Asked(book: book, chapter: chapter, state: $0)
                }
            }
        }
    }

    private var isEmpty: Bool {
        converter?.active == nil && waiting.isEmpty && asked.isEmpty
    }

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()
            if isEmpty {
                empty
            } else {
                list
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only the local queue: what the Mac has been asked for is
            // cancelled one row at a time, because it is the slower thing to
            // rebuild and the easier thing to lose by accident.
            if converter?.active != nil || !waiting.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel all", role: .destructive) { converter?.cancelAll() }
                        .font(.huiverLabel)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Palette.Space.sm) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.colors.mutedForeground)
            Text("Nothing queued")
                .font(.huiverLabel)
                .foregroundStyle(theme.colors.foreground)
            Text("Convert a chapter from its book and it will appear here.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .padding(Palette.Space.xl)
    }

    private var list: some View {
        List {
            if let active = converter?.active {
                Section("Converting") {
                    JobRow(job: active, isActive: true)
                }
                .listRowBackground(theme.colors.card)
            }
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting) { JobRow(job: $0, isActive: false) }
                        .onDelete { offsets in
                            for index in offsets { converter?.cancel(waiting[index].chapterId) }
                        }
                }
                .listRowBackground(theme.colors.card)
            }
            if !asked.isEmpty {
                Section("On the Mac") {
                    ForEach(asked) { AskedRow(asked: $0) }
                        .onDelete { offsets in
                            let rows = asked
                            for index in offsets {
                                Task { await model.cancelMacRequest(chapter: rows[index].chapter) }
                            }
                        }
                }
                .listRowBackground(theme.colors.card)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// One chapter the Mac has been asked for.
private struct Asked: Identifiable {
    let book: Book
    let chapter: Chapter
    let state: AppModel.OffloadState
    var id: String { chapter.id }
}

private struct AskedRow: View {
    let asked: Asked

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    private var voiceName: String {
        model.voices.first { $0.id == asked.state.voiceId }?.name ?? asked.state.voiceId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            Text(asked.chapter.title)
                .font(.huiverBody)
                .foregroundStyle(theme.colors.foreground)
                .lineLimit(1)
            Text(detail)
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
            if let status = asked.state.status, status.state == .rendering, status.chunkCount > 0 {
                ProgressView(
                    value: Double(status.renderedChunks) / Double(status.chunkCount)
                )
                .tint(theme.colors.primary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [asked.book.title, "read by \(voiceName)"]
        switch asked.state.status?.state {
        case nil: parts.append("waiting for the next sync")
        case .queued: parts.append("queued on the Mac")
        case .rendering:
            let status = asked.state.status
            parts.append("\(status?.renderedChunks ?? 0)/\(max(status?.chunkCount ?? 1, 1))")
        case .done: parts.append("done — sync to fetch it")
        case .failed: parts.append("the Mac could not render it")
        }
        return parts.joined(separator: " · ")
    }
}

private struct JobRow: View {
    let job: Converter.Job
    let isActive: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    /// Jobs carry ids, not titles — the library is where the words live.
    private var book: Book? { model.books.first { $0.id == job.bookId } }
    private var chapter: Chapter? { book?.chapters.first { $0.id == job.chapterId } }
    private var voiceName: String {
        model.voices.first { $0.id == job.voiceId }?.name ?? job.voiceId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            Text(chapter?.title ?? "Chapter")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.foreground)
                .lineLimit(1)
            Text(detail)
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
                .lineLimit(1)
            if isActive, let fraction = model.converter?.progress(for: job.chapterId) {
                ProgressView(value: fraction)
                    .tint(theme.colors.primary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if let title = book?.title { parts.append(title) }
        parts.append("read by \(voiceName)")
        if isActive, let converter = model.converter, converter.chunkCount > 0 {
            parts.append("\(converter.renderedChunks)/\(converter.chunkCount)")
        }
        return parts.joined(separator: " · ")
    }
}
