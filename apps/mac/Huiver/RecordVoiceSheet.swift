import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The Voices-screen entrance to `VoiceCaptureView`: a sheet that closes when
/// the voice exists or the person backs out.
struct RecordVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VoiceCaptureView(onDone: { _ in dismiss() }, onCancel: { dismiss() })
    }
}

/// Record fifteen seconds, get a voice.
///
/// The passage matters more than it looks. A clone is built from one continuous
/// stretch of speech, so what it hears is what it imitates: reading a varied
/// sentence at a normal pace gives it something to generalise from, while
/// counting to ten teaches it to count. The suggested text is there to be read
/// rather than to be admired.
///
/// Shared between the Voices sheet and onboarding, so finishing and backing
/// out are injected rather than assuming a dismissible container.
struct VoiceCaptureView: View {
    let onDone: (Voice) -> Void
    let onCancel: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var recorder = VoiceRecorder()
    @State private var name = ""
    @State private var cloning = false
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var languageCode = Language.english.code
    @State private var preview = SamplePreviewPlayer()

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

            if recorder.state == .finished {
                sampleEditor
            } else {
                meter
            }
            controls

            if let message = failure ?? recorder.failure {
                Text(message).font(.huiverCaption).foregroundStyle(theme.colors.destructive)
            }
        }
        .padding(Palette.Space.xl)
        .frame(width: 520)
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                recorder.importAudio(from: url)
                if let suggested = recorder.sourceName { name = suggested }
                resetTrim()
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
        .onChange(of: recorder.state) { _, state in
            preview.stop()
            if state == .finished { resetTrim() }
        }
        .onDisappear { preview.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            Text("Add your voice").font(.huiverTitle)
            Text(
                recorder.state == .denied
                    ? "Narcisse needs the microphone. Allow it in System Settings ▸ Privacy & "
                        + "Security ▸ Microphone, then reopen this window."
                    : "Record the passage below, or upload a clear audio sample. Trim it to "
                        + "the part that sounds most like you. The original is never kept."
            )
            .font(.huiverCaption)
            .foregroundStyle(theme.colors.mutedForeground)
        }
    }

    private var sampleEditor: some View {
        VStack(alignment: .leading, spacing: Palette.Space.sm) {
            HStack {
                Text(recorder.sourceName ?? "Your recording")
                    .font(.huiverCaption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button(preview.playing ? "Stop preview" : "Preview", systemImage: preview.playing ? "stop.fill" : "play.fill") {
                    preview.toggle(selectedSamples)
                }
                .disabled(selectedSamples.isEmpty)
                Text(String(format: "%.1fs selected", selectedDuration))
                    .font(.huiverCaption.monospacedDigit())
                    .foregroundStyle(
                        selectedDuration < VoiceCloner.minimumSeconds
                            ? theme.colors.destructive : theme.colors.mutedForeground
                    )
            }

            WaveformTrimmer(
                samples: recorder.samples,
                duration: recorder.seconds,
                start: $trimStart,
                end: $trimEnd,
                tint: theme.colors.primary,
                muted: theme.colors.mutedForeground
            )
            .frame(height: 104)
            .onChange(of: trimStart) { preview.stop() }
            .onChange(of: trimEnd) { preview.stop() }

            HStack {
                Text(time(trimStart))
                Spacer()
                Text("Drag the handles to choose the clearest section")
                Spacer()
                Text(time(trimEnd))
            }
            .font(.huiverCaption.monospacedDigit())
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
        guard let choice = selectedChoice else { return "Ready" }
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

    @ViewBuilder
    private var controls: some View {
        switch recorder.state {
        case .idle, .denied:
            HStack(spacing: Palette.Space.md) {
                Button("Start recording", systemImage: "mic.fill") {
                    if model.narrator?.state == .speaking { model.narrator?.pause() }
                    Task {
                        if await recorder.requestAccess() { recorder.start() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.state == .denied)
                Button("Upload audio…", systemImage: "waveform.badge.plus") {
                    choosingFile = true
                }
                Spacer()
                Button("Cancel") { onCancel() }
            }

        case .recording:
            HStack(spacing: Palette.Space.md) {
                Button("Stop", systemImage: "stop.fill") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { recorder.reset(); onCancel() }
            }

        case .finished:
            VStack(alignment: .leading, spacing: Palette.Space.md) {
                HStack(alignment: .top, spacing: Palette.Space.md) {
                    VStack(alignment: .leading, spacing: Palette.Space.xs) {
                        Text("Voice name").font(.huiverCaption.weight(.semibold))
                        TextField("For example, Peter", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { create() }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: Palette.Space.xs) {
                        Text("Sample language").font(.huiverCaption.weight(.semibold))
                        Picker("Sample language", selection: $languageCode) {
                            ForEach(model.engineLanguages) { language in
                                Text(language.name).tag(language.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }

                HStack(spacing: Palette.Space.md) {
                    Menu("Replace sample…") {
                        Button("Record again", systemImage: "mic.fill") { recorder.reset() }
                        Button("Choose another file…", systemImage: "waveform.badge.plus") {
                            choosingFile = true
                        }
                    }
                    Spacer()
                    Button("Cancel") { onCancel() }
                    Button(cloning ? "Creating…" : "Create voice") { create() }
                        .buttonStyle(.borderedProminent)
                        .disabled(cloning || !isUsable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .overlay(alignment: .trailing) {
                            if cloning { ProgressView().controlSize(.small).offset(x: 26) }
                        }
                }
            }
        }
    }

    /// Whether the take is worth cloning. The cloner refuses the same cases
    /// with a reason; this stops the button rather than waiting to explain.
    private var isUsable: Bool {
        guard let choice = selectedChoice else { return false }
        return choice.peak > 0.02 && choice.availableSeconds >= VoiceCloner.minimumSeconds
    }

    private var selectedDuration: Double { max(0, trimEnd - trimStart) }

    private var selectedSamples: [Float] {
        let rate = Double(ReferenceClip.sampleRate)
        let lower = min(recorder.samples.count, max(0, Int(trimStart * rate)))
        let upper = min(recorder.samples.count, max(lower, Int(trimEnd * rate)))
        return Array(recorder.samples[lower..<upper])
    }

    private var selectedChoice: ReferenceClip.Choice? {
        selectedSamples.isEmpty ? nil : ReferenceClip.prepare(selectedSamples)
    }

    private func resetTrim() {
        trimStart = 0
        trimEnd = recorder.seconds
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func create() {
        guard isUsable, !cloning else { return }
        cloning = true
        failure = nil
        Task {
            do {
                let voice = try await model.cloneVoice(
                    from: selectedSamples,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: .named(languageCode)
                )
                onDone(voice)
            } catch {
                failure = error.localizedDescription
            }
            cloning = false
        }
    }
}

/// Plays the currently selected raw reference range without waking the model.
@MainActor
@Observable
private final class SamplePreviewPlayer {
    private(set) var playing = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    func toggle(_ samples: [Float]) {
        if playing {
            stop()
            return
        }
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(ReferenceClip.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ), let channel = buffer.floatChannelData?[0]
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        if node.engine == nil {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }

        do {
            try engine.start()
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.finished() }
            }
            node.play()
            playing = true
        } catch {
            stop()
        }
    }

    func stop() {
        node.stop()
        engine.stop()
        playing = false
    }

    private func finished() {
        guard playing else { return }
        engine.stop()
        playing = false
    }
}

/// A compact SoundCloud-style overview with independently draggable in/out points.
private struct WaveformTrimmer: View {
    let samples: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let tint: Color
    let muted: Color

    private let bars = 110
    private let minimumSelection = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let left = width * start / max(duration, 0.001)
            let right = width * end / max(duration, 0.001)

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 1) {
                    ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                        Capsule()
                            .fill(tint.opacity(0.82))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(4, geometry.size.height * 0.82 * CGFloat(peak)))
                    }
                }
                .frame(maxHeight: .infinity)

                Rectangle().fill(Color.black.opacity(0.38)).frame(width: left)
                Rectangle().fill(Color.black.opacity(0.38))
                    .frame(width: max(0, width - right))
                    .offset(x: right)

                handle(at: left, width: width, isStart: true)
                handle(at: right, width: width, isStart: false)
            }
            .coordinateSpace(name: "waveform")
            .background(muted.opacity(0.12), in: .rect(cornerRadius: Palette.Radius.md))
            .clipShape(.rect(cornerRadius: Palette.Radius.md))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio trim range")
        .accessibilityValue("From \(time(start)) to \(time(end))")
    }

    private func handle(at x: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: 5)
            .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1))
            .frame(width: 22)
            .contentShape(Rectangle())
            .offset(x: min(max(0, x - 11), width - 22))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform")).onChanged { value in
                    let seconds = Double(min(max(0, value.location.x), width) / width) * duration
                    if isStart {
                        start = min(seconds, end - minimumSelection)
                    } else {
                        end = max(seconds, start + minimumSelection)
                    }
                }
            )
    }

    private var peaks: [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0.05, count: bars) }
        let stride = max(1, samples.count / bars)
        var result: [Float] = []
        result.reserveCapacity(bars)
        for bar in 0..<bars {
            let lower = min(samples.count, bar * stride)
            let upper = min(samples.count, lower + stride)
            let sampling = max(1, stride / 100)
            var peak: Float = 0
            var index = lower
            while index < upper {
                peak = max(peak, abs(samples[index]))
                index += sampling
            }
            result.append(max(0.04, peak))
        }
        let maximum = max(result.max() ?? 1, 0.001)
        return result.map { $0 / maximum }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d minutes %.1f seconds", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
