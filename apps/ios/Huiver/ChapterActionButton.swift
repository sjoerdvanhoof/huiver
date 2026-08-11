import SwiftUI

/// The download control from a podcast app.
///
/// An arrow to render the chapter, a ring filling with progress while it works,
/// a tick once the audio is on disk. Tapping mid-render stops it — which is a
/// pause, not a discard: the chunks already written are kept and picked up next
/// time. A port of `apps/mobile/src/components/ChapterAction.tsx`.
struct ChapterActionButton: View {
    enum State: Equatable {
        case none
        case rendering(Double?)
        case done
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
    }

    private var label: String {
        switch state {
        case .none: "Render this chapter"
        case .rendering: "Stop rendering"
        case .done: "Rendered"
        }
    }
}
