import SwiftUI

/// The bar above the bottom edge: cover, chapter, play/pause, and a hairline of
/// progress. Tapping it opens the full player, exactly as on the web.
///
/// The progress hairline has two fills. The dim one is how far synthesis has
/// got; the ember one is how far playback has. Keeping them apart matters here,
/// because the part that has not been rendered yet is not merely unbuffered —
/// it does not exist, and cannot be seeked into.
struct MiniPlayer: View {
    let open: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let narrator = model.narrator, narrator.chapterId != nil {
            Button(action: open) {
                VStack(spacing: 0) {
                    TwoStageBar(
                        played: fraction(narrator.position, of: narrator),
                        rendered: fraction(narrator.renderedSeconds, of: narrator),
                        height: 2
                    )

                    HStack(spacing: Palette.Space.md) {
                        if let book = narrator.book {
                            BookCover(
                                bookId: book.id,
                                title: book.title,
                                url: model.coverURL(for: book),
                                width: 34,
                                radius: Palette.Radius.sm
                            )
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(narrator.chapterTitle)
                                .font(.huiverLabel)
                                .foregroundStyle(theme.colors.foreground)
                                .lineLimit(1)
                            Text(status(narrator))
                                .font(.huiverCaption)
                                .foregroundStyle(theme.colors.mutedForeground)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Button {
                            narrator.state == .speaking ? narrator.pause() : narrator.resume()
                        } label: {
                            Image(systemName: narrator.state == .speaking ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.colors.primaryForeground)
                                .frame(width: 38, height: 38)
                                .background(theme.colors.primary, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(narrator.state == .preparing)
                    }
                    .padding(.horizontal, Palette.Space.md)
                    .padding(.vertical, Palette.Space.sm)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func fraction(_ seconds: Double, of narrator: Narrator) -> Double {
        guard narrator.estimatedDuration > 0 else { return 0 }
        return min(1, seconds / narrator.estimatedDuration)
    }

    private func status(_ narrator: Narrator) -> String {
        switch narrator.state {
        case .preparing: "Reading ahead…"
        case .failed(let message): message
        case .idle: "Finished"
        case .speaking, .paused:
            "\(Format.duration(narrator.position)) / \(narrator.isFullyRendered ? "" : "~")\(Format.duration(narrator.estimatedDuration))"
        }
    }
}

/// A progress track with a rendered-so-far layer behind the played layer.
struct TwoStageBar: View {
    let played: Double
    let rendered: Double
    var height: CGFloat = 4

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                theme.colors.border
                theme.colors.mutedForeground.opacity(0.45)
                    .frame(width: geometry.size.width * min(1, max(0, rendered)))
                theme.colors.primary
                    .frame(width: geometry.size.width * min(1, max(0, played)))
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: height / 2))
    }
}
