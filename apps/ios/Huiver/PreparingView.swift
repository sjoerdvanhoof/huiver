import SwiftUI

/// Shown while Core ML gets the models ready for this device.
///
/// On the first run after installing this takes several minutes, because Core ML
/// compiles each model for the specific chip and that cannot be done ahead of
/// time on the Mac. It is worth a screen of its own: without one the app looks
/// like it has hung, which is exactly what it looks like when it has.
struct PreparingView: View {
    let progress: ChatterboxEngine.LoadProgress
    let since: Date?
    let firstRun: Bool

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            VStack(spacing: 6) {
                Text(firstRun ? "Getting Chatterbox Nano ready" : "Loading the voice model")
                    .font(.headline)
                if firstRun {
                    Text("Core ML is compiling the model for this iPhone. It only happens once — after this, starting up takes a moment.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: 8) {
                ProgressView(value: progress.fraction)
                    .tint(.accentColor)
                HStack {
                    Text("\(progress.model) · \(progress.index) of \(progress.total)")
                    Spacer()
                    if let since {
                        // A clock rather than a guess at what is left: the
                        // remaining time depends on how long the compiler takes,
                        // which nothing here can see.
                        Text(since, style: .timer).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if firstRun {
                Label(
                    "Keep the screen on. iOS pauses the work if you leave the app.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}
