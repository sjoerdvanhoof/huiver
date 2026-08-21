import SwiftUI

/// The thin bar under the detail pane: what is being read, transport, speed.
///
/// Clicking the cover or the title opens the full player, exactly as on the
/// phone; the transport stays here so listening never requires leaving the
/// screen you are on. The progress track has two fills: the dim one is how far
/// synthesis has got, the ember one how far playback has. The part not yet
/// rendered is not merely unbuffered — it does not exist, and cannot be
/// seeked into.
struct MiniPlayerBar: View {
    let open: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var dragging: Double?

    var body: some View {
        if let narrator = model.narrator, narrator.chapterId != nil {
            VStack(spacing: 0) {
                scrubber(narrator)

                HStack(spacing: Palette.Space.md) {
                    Button(action: open) {
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
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open the player")

                    Spacer(minLength: 0)

                    Button { narrator.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                            .foregroundStyle(theme.colors.foreground)
                    }
                    .buttonStyle(.plain)

                    Button {
                        narrator.state == .speaking ? narrator.pause() : narrator.resume()
                    } label: {
                        Image(systemName: narrator.state == .speaking ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.colors.primaryForeground)
                            .frame(width: 32, height: 32)
                            .background(theme.colors.primary, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(narrator.state == .preparing)

                    Button { narrator.skip(by: 30) } label: {
                        Image(systemName: "goforward.30")
                            .foregroundStyle(theme.colors.foreground)
                    }
                    .buttonStyle(.plain)

                    rateMenu(narrator)

                    Button { narrator.stop() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
                .padding(.horizontal, Palette.Space.lg)
                .padding(.vertical, Palette.Space.sm)
            }
        }
    }

    /// A draggable track rather than a hairline: thin enough to stay a border,
    /// with the drag target inset outward so it can actually be grabbed. The
    /// drag is clamped to the rendered edge, same as the full player.
    private func scrubber(_ narrator: Narrator) -> some View {
        let total = max(narrator.estimatedDuration, 1)

        return GeometryReader { geometry in
            TwoStageBar(
                played: (dragging ?? narrator.position) / total,
                rendered: narrator.renderedSeconds / total,
                height: 3
            )
            .contentShape(.rect.inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(1, max(0, value.location.x / geometry.size.width))
                        dragging = min(fraction * total, narrator.renderedSeconds)
                    }
                    .onEnded { _ in
                        if let target = dragging { narrator.seek(to: target) }
                        dragging = nil
                    }
            )
        }
        .frame(height: 3)
    }

    /// Speed. The model has no speed control of its own, so this is the player
    /// stretching time — pitch-corrected, so it still sounds like the same
    /// narrator.
    private func rateMenu(_ narrator: Narrator) -> some View {
        Menu {
            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    narrator.rate = Float(rate)
                } label: {
                    if abs(Double(narrator.rate) - rate) < 0.01 {
                        Label("\(rate.formatted())×", systemImage: "checkmark")
                    } else {
                        Text("\(rate.formatted())×")
                    }
                }
            }
        } label: {
            Text("\(Double(narrator.rate).formatted())×")
                .font(.huiverLabel)
                .foregroundStyle(theme.colors.foreground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
