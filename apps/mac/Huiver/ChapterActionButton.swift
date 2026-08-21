import SwiftUI

/// The download control from a podcast app.
///
/// An arrow to render the chapter, a ring filling with progress while it works,
/// a tick once the audio is on disk. Clicking mid-render stops it — which is a
/// pause, not a discard: the chunks already written are kept and picked up next
/// time. The same control as on the phone.
struct ChapterActionButton: View {
    enum State: Equatable {
        case none
        case rendering(Double?)
        /// Some chunks are on disk but the render was stopped. The ring shows
        /// how far it got; clicking carries on from there.
        case partial(Double)
        case done
        /// The last attempt stopped badly. Clicking tries again.
        case failed
    }

    let state: State
    let action: () -> Void

    @Environment(\.theme) private var theme

    private let size: CGFloat = 30

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(theme.colors.primary)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.colors.primaryForeground)

                case .rendering(let fraction):
                    Circle().strokeBorder(theme.colors.border, lineWidth: 1.5)
                    if let fraction {
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(
                                theme.colors.primary,
                                style: .init(lineWidth: 1.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    // A square, because this is a stop button while it works.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.colors.primary)
                        .frame(width: 8, height: 8)

                case .partial(let fraction):
                    Circle().strokeBorder(theme.colors.border, lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(
                            theme.colors.primary,
                            style: .init(lineWidth: 1.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    // The arrow rather than the square: nothing is running, so
                    // this is a resume button, not a stop button.
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.primary)

                case .failed:
                    Circle().strokeBorder(theme.colors.destructive, lineWidth: 1.5)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.colors.destructive)

                case .none:
                    Circle().strokeBorder(theme.colors.border, lineWidth: 1.5)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.mutedForeground)
                }
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.25), value: state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var label: String {
        switch state {
        case .none: "Convert this chapter"
        case .rendering: "Stop conversion"
        case .partial: "Resume conversion"
        case .done: "Converted"
        case .failed: "Conversion failed — try again"
        }
    }
}
