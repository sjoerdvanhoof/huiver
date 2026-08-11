import SwiftUI

/// The strip along the bottom, shown only while something is being read.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let narrator = model.narrator, narrator.chapterId != nil {
            VStack(spacing: 6) {
                if narrator.chunkCount > 0 {
                    ProgressView(
                        value: Double(narrator.renderedChunks),
                        total: Double(narrator.chunkCount)
                    )
                    .tint(.accentColor)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(narrator.chapterTitle).font(.subheadline).lineLimit(1)
                        Text(status(narrator)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        narrator.state == .speaking ? narrator.pause() : narrator.resume()
                    } label: {
                        Image(systemName: narrator.state == .speaking ? "pause.fill" : "play.fill")
                    }
                    .disabled(narrator.state == .preparing)
                    Button { narrator.stop() } label: { Image(systemName: "stop.fill") }
                }
                .font(.title3)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func status(_ narrator: Narrator) -> String {
        switch narrator.state {
        case .preparing: "warming up the model…"
        case .speaking, .paused:
            // What exists, not what is playing: the render is what the reader
            // is waiting on, and it is the honest number.
            "\(narrator.renderedChunks)/\(narrator.chunkCount) rendered · \(format(narrator.renderedSeconds))"
        case .failed(let message): message
        case .idle: "done"
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
