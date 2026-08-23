import SwiftUI

/// The ambient load indicator, exactly as `apps/ios/Huiver/Waterline.swift`
/// has it: a band of gold water that rises as the models load and stills to a
/// flat line when they are ready. Pinned under the detail pane so progress is
/// visible from every sidebar destination, not just the library.
struct WaterlineView: View {
    /// Load progress, 0…1. The level rises and the chop calms as it grows.
    let fraction: Double
    /// When loading finished; drives the stilling of the surface.
    let resolvedAt: Date?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let level = size.height * (0.85 - 0.5 * fraction)
                // Chop calms as the pool fills, and dies entirely once done.
                var amplitude = reduceMotion ? 0 : 6 * (1 - 0.7 * fraction)
                if let resolvedAt {
                    let elapsed = Date().timeIntervalSince(resolvedAt)
                    amplitude *= max(0, 1 - elapsed / 1.4)
                }

                let waves: [(speed: Double, wavelength: Double, opacity: Double)] = [
                    (0.6, 2.0, 0.10),
                    (1.0, 1.2, 0.14),
                    (1.5, 0.8, 0.18),
                ]
                for (index, wave) in waves.enumerated() {
                    let path = crest(
                        size: size, level: level, amplitude: amplitude,
                        phase: now * wave.speed + Double(index) * 2,
                        wavelength: size.width * wave.wavelength
                    )
                    var fill = path
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    context.fill(fill, with: .color(theme.colors.primary.opacity(wave.opacity)))
                    if index == waves.count - 1 {
                        context.stroke(
                            path,
                            with: .color(theme.colors.primary.opacity(0.55)),
                            lineWidth: 1
                        )
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func crest(
        size: CGSize, level: Double, amplitude: Double,
        phase: Double, wavelength: Double
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: level + amplitude * sin(phase)))
        let step: CGFloat = 4
        var x: CGFloat = step
        while x <= size.width + step {
            let y = level + amplitude * sin(phase + Double(x) / wavelength * 2 * .pi)
            path.addLine(to: CGPoint(x: min(x, size.width), y: y))
            x += step
        }
        return path
    }
}

/// The strip that hosts the waterline while the models load: caption over
/// water. It stays mounted through the stilling so the calm-then-fade reads,
/// rather than vanishing the instant progress hits nil.
struct PreparingWaterline: View {
    let progress: ChatterboxEngine.LoadProgress?
    let since: Date?
    let firstRun: Bool

    @Environment(\.theme) private var theme
    @State private var phase = Phase.hidden
    @State private var resolvedAt: Date?

    enum Phase { case hidden, filling, stilling }

    var body: some View {
        Group {
            if phase != .hidden {
                caption
                    .padding(.horizontal, Palette.Space.lg)
                    .padding(.vertical, Palette.Space.sm)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)
                    .background { WaterlineView(fraction: fraction, resolvedAt: resolvedAt) }
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            }
        }
        .onChange(of: progress != nil, initial: true) { _, loading in
            if loading {
                phase = .filling
                resolvedAt = nil
            } else if phase == .filling {
                phase = .stilling
                resolvedAt = Date()
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    withAnimation(.easeOut(duration: 0.5)) { phase = .hidden }
                }
            }
        }
    }

    /// The last reported fraction survives into the stilling, where progress
    /// itself has already gone nil — a full pool, going calm.
    private var fraction: Double {
        progress?.fraction ?? (phase == .stilling ? 1 : 0)
    }

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                if phase == .filling, let since {
                    Text(since, style: .timer).monospacedDigit()
                }
            }
            if firstRun, phase == .filling {
                Text("First launch compiles the voice model for this Mac — a few minutes, once.")
            }
        }
        .font(.huiverCaption)
        .foregroundStyle(theme.colors.mutedForeground)
    }

    private var label: String {
        if let progress {
            return "Preparing your narrator · \(progress.model) · \(progress.index) of \(progress.total)"
        }
        return "Your narrator is ready"
    }
}
