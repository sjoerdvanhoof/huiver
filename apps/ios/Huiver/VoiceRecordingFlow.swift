import AVFoundation
import SwiftUI

/// The record-a-voice flow, shared between the Settings sheet and onboarding.
///
/// Three states rather than a wizard: nothing recorded, recording, and a take
/// to keep or throw away. The one number that shapes all of them is how much
/// speech the cloner wants — fifteen seconds for Nano — because a clip that
/// falls short is padded with silence, and padding is the one thing that
/// measurably makes a worse clone (see `ReferenceClip`). So the flow asks for
/// more than it needs and says how it is getting on.
///
/// The caller owns the recorder (so it can gate dismissal on `.recording`) and
/// decides what submitting means: the sheet clones and dismisses, onboarding
/// queues the clone and moves on.
struct VoiceRecordingFlow: View {
    let recorder: VoiceRecorder
    /// The submit button's label — "Create voice" or "Use my voice".
    let submitLabel: String
    /// The caller's clone-in-flight state; disables the buttons.
    let busy: Bool
    /// A caller-supplied error line, shown alongside the recorder's own.
    let failure: String?
    let onSubmit: (_ samples: [Float], _ name: String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var preview = TakePlayer()

    /// How many seconds of speech the installed cloner reads. Nano's window is
    /// fifteen; asking the package beats hardcoding it here and drifting.
    private var wanted: Int {
        model.modelDirectory.flatMap(VoiceCloner.clipSeconds) ?? 15
    }

    /// Long enough that reading it unhurried fills the window.
    private let passage = """
        The quiet harbour town woke slowly, and the gulls turned above the \
        jetty as though they had all morning. Down on the front, the shutters \
        went up one at a time, and somebody was already arguing pleasantly \
        about the price of fish.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xl) {
            switch recorder.state {
            case .idle, .denied: introduction
            case .recording: recording
            case .finished: take
            }
            if let message = failure ?? recorder.failure {
                Text(message)
                    .font(.huiverBody)
                    .foregroundStyle(theme.colors.destructive)
            }
        }
        .onDisappear { preview.stop() }
    }

    // MARK: - Nothing recorded yet

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            Text("Read this aloud for about \(wanted) seconds, in the voice you would want a book read in.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.mutedForeground)

            Text(passage)
                .font(.system(.body, design: .serif))
                .foregroundStyle(theme.colors.foreground)
                .padding(Palette.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))

            if recorder.state == .denied {
                Text("Narcisse cannot hear the microphone. Turn it on in Settings › Privacy & Security › Microphone.")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.destructive)
            }

            Button {
                Task {
                    guard await recorder.requestAccess() else { return }
                    recorder.start()
                }
            } label: {
                Label("Start recording", systemImage: "mic.fill")
                    .font(.huiverHeading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Palette.Space.md)
            }
            .buttonStyle(.borderedProminent)

            Text("The recording stays on this phone. What is kept is five small tensors describing the voice, and none of them can be turned back into audio.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
        }
    }

    // MARK: - Recording

    private var recording: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            Text(passage)
                .font(.system(.body, design: .serif))
                .foregroundStyle(theme.colors.foreground)

            LevelMeter(level: recorder.level)

            // Against what the cloner wants rather than against the maximum:
            // the bar filling is the thing worth watching.
            VStack(alignment: .leading, spacing: Palette.Space.xs) {
                ProgressView(value: min(1, recorder.seconds / Double(wanted)))
                    .tint(recorder.seconds >= Double(wanted)
                        ? theme.colors.primary : theme.colors.mutedForeground)
                Text(recorder.seconds >= Double(wanted)
                    ? "\(Int(recorder.seconds))s — that is enough, stop whenever you like"
                    : "\(Int(recorder.seconds))s of \(wanted)")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }

            Button {
                recorder.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.huiverHeading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Palette.Space.md)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - A take to keep or throw away

    private var take: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            if let choice = recorder.choice(seconds: wanted) {
                Text(summary(choice))
                    .font(.huiverBody)
                    .foregroundStyle(
                        choice.availableSeconds < Double(wanted)
                            ? theme.colors.destructive : theme.colors.mutedForeground
                    )

                Button {
                    preview.toggle(choice.samples)
                } label: {
                    Label(
                        preview.isPlaying ? "Stop" : "Hear the \(wanted) seconds",
                        systemImage: preview.isPlaying ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: Palette.Space.xs) {
                Text("Voice name").font(.huiverLabel)
                    .foregroundStyle(theme.colors.mutedForeground)
                TextField("My voice", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
            }

            Button {
                preview.stop()
                onSubmit(
                    recorder.samples,
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } label: {
                Text(busy ? "Creating…" : submitLabel)
                    .font(.huiverHeading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Palette.Space.md)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button {
                preview.stop()
                recorder.reset()
            } label: {
                Label("Record again", systemImage: "mic.fill")
            }
            .buttonStyle(.bordered)
            .disabled(busy)

            if busy {
                Text("Loading the cloning model and reading the clip. It is only held for this, so it takes a few seconds.")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
    }

    private func summary(_ choice: ReferenceClip.Choice) -> String {
        let available = Int(choice.availableSeconds.rounded())
        if choice.availableSeconds < Double(wanted) {
            return "\(available)s of speech. The clip is padded with silence to "
                + "\(wanted)s, which makes a rougher voice — recording again for "
                + "longer is worth it."
        }
        return "\(available)s of speech; the clearest \(wanted) of it will be used, "
            + "from \(Format.duration(choice.startSeconds))."
    }
}

/// A bar that follows the microphone, so a silent input is visible before
/// fifteen seconds have been wasted on it.
private struct LevelMeter: View {
    let level: Double

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                theme.colors.muted
                theme.colors.primary
                    .frame(width: geometry.size.width * min(1, max(0.01, level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
        .accessibilityLabel("Input level")
    }
}

/// Plays the take back, from the samples rather than from a file the flow
/// would then have to clean up. `WavFile` is already the format the renderer
/// writes, so this is one call and a temporary.
@MainActor
@Observable
private final class TakePlayer {
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(_ samples: [Float]) {
        if isPlaying {
            stop()
            return
        }
        do {
            let url = URL.temporaryDirectory.appendingPathComponent("huiver-take.wav")
            try WavFile.data(from: samples).write(to: url, options: .atomic)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
            // No delegate: a timer a moment past the end is enough to put the
            // button back, and avoids an @objc shim for eight seconds of audio.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                self?.stop()
            }
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
