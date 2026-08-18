import SwiftUI

/// Everything waiting to be converted: the job being worked on, then the line
/// behind it. Rows carry an explicit cancel button — the Mac has no
/// swipe-to-delete for a List row to lean on.
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

    var body: some View {
        ZStack {
            theme.colors.background.ignoresSafeArea()
            if converter?.active == nil, waiting.isEmpty {
                empty
            } else {
                list
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            if converter?.active != nil || !waiting.isEmpty {
                ToolbarItem(placement: .primaryAction) {
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
            }
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting) { JobRow(job: $0, isActive: false) }
                }
            }
        }
        .scrollContentBackground(.hidden)
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
        HStack(spacing: Palette.Space.md) {
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

            Spacer(minLength: 0)

            Button {
                model.converter?.cancel(job.chapterId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.colors.mutedForeground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "Stop converting" : "Remove from queue")
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
