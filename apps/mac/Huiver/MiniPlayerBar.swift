import SwiftUI

/// The thin bar under the detail pane: what is being read, transport, speed.
///
/// This is an audition bar, not a full player — the Mac's job is to render and
/// to sync, and listening here is mostly checking a voice against a chapter.
/// The progress hairline has two fills: the dim one is how far synthesis has
/// got, the ember one how far playback has. The part not yet rendered is not
/// merely unbuffered — it does not exist, and cannot be seeked into.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        if let narrator = model.narrator, narrator.chapterId != nil {
            VStack(spacing: 0) {
                TwoStageBar(
                    played: fraction(narrator.position, of: narrator),
                    rendered: fraction(narrator.renderedSeconds, of: narrator),
                    height: 2
                )

                HStack(spacing: Palette.Space.md) {
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
