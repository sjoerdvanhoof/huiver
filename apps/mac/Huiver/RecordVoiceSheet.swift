import SwiftUI

/// Record fifteen seconds, get a voice.
///
/// The passage matters more than it looks. A clone is built from one continuous
/// stretch of speech, so what it hears is what it imitates: reading a varied
/// sentence at a normal pace gives it something to generalise from, while
/// counting to ten teaches it to count. The suggested text is there to be read
/// rather than to be admired.
struct RecordVoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = VoiceRecorder()
    @State private var name = ""
    @State private var cloning = false
    @State private var failure: String?

    /// Long enough to contain the ten seconds the model wants, ordinary enough
    /// to be read the way this person actually speaks.
    private let passage = """
        The harbour was quiet at that hour, and the water held the light like a \
        sheet of glass. I walked to the end of the pier, counted the boats — \
        eleven, maybe twelve — and turned back towards the town before the bells \
        rang.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            header

            Text(passage)
                .font(.huiverBody)
                .foregroundStyle(theme.colors.foreground)
                .padding(Palette.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.colors.muted, in: .rect(cornerRadius: Palette.Radius.lg))

            meter
            controls

            if let message = failure ?? recorder.failure {
                Text(message).font(.huiverCaption).foregroundStyle(theme.colors.destructive)
            }
        }
        .padding(Palette.Space.xl)
        .frame(width: 520)
        .task { _ = await recorder.requestAccess() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            Text("Record a voice").font(.huiverTitle)
            Text(
                recorder.state == .denied
                    ? "Huiver needs the microphone. Allow it in System Settings ▸ Privacy & "
                        + "Security ▸ Microphone, then reopen this window."
                    : "Read the passage below at your normal pace. Fifteen seconds is plenty; "
                        + "the app keeps the best ten and throws the recording away."
            )
            .font(.huiverCaption)
            .foregroundStyle(theme.colors.mutedForeground)
        }
    }

    /// A level meter and a clock, which together answer "is it hearing me".
    private var meter: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.colors.muted)
                    Capsule()
                        .fill(recorder.level > 0.95 ? theme.colors.destructive : theme.colors.primary)
                        .frame(width: geometry.size.width * min(1, recorder.level))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.08), value: recorder.level)

            HStack {
                Text(status)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
                Spacer()
                Text(String(format: "%.1fs", recorder.seconds))
                    .font(.huiverCaption.monospacedDigit())
                    .foregroundStyle(theme.colors.mutedForeground)
            }
        }
    }

    private var status: String {
        if recorder.state == .recording {
            return recorder.level > 0.95 ? "Too loud — sit back a little" : "Recording"
        }
        guard let choice = recorder.choice else { return "Ready" }
        if choice.peak < 0.02 { return "That came out very quiet — try again closer in" }
        if choice.availableSeconds < VoiceCloner.minimumSeconds {
            return String(
                format: "Only %.1fs of speech — read a little more", choice.availableSeconds
            )
        }
        return String(
            format: "%.0fs of speech, using from %.0fs in",
            choice.availableSeconds, choice.startSeconds
        )
    }

    private var controls: some View {
        HStack(spacing: Palette.Space.md) {
            switch recorder.state {
            case .idle, .denied:
                Button("Start recording", systemImage: "mic.fill") {
                    // One voice at a time: a book reading itself into the
                    // reference clip would be cloned along with the speaker.
                    if model.narrator?.state == .speaking { model.narrator?.pause() }
                    recorder.start()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.state == .denied)
                Spacer()
                Button("Cancel") { dismiss() }

            case .recording:
                Button("Stop", systemImage: "stop.fill") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { recorder.reset(); dismiss() }

            case .finished:
                TextField("Name this voice", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { create() }
                Button("Record again") { recorder.reset() }
                Spacer()
                Button(cloning ? "Creating…" : "Create voice") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cloning || !isUsable)
            }
        }
        .overlay(alignment: .trailing) {
            if cloning { ProgressView().controlSize(.small).offset(x: 26) }
        }
    }

    /// Whether the take is worth cloning. The cloner refuses the same cases
    /// with a reason; this stops the button rather than waiting to explain.
    private var isUsable: Bool {
        guard let choice = recorder.choice else { return false }
        return choice.peak > 0.02 && choice.availableSeconds >= VoiceCloner.minimumSeconds
    }

    private func create() {
        guard isUsable, !cloning else { return }
        cloning = true
        failure = nil
        Task {
            do {
                _ = try await model.cloneVoice(
                    from: recorder.samples, name: name.isEmpty ? "My voice" : name
                )
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            cloning = false
        }
    }
}
