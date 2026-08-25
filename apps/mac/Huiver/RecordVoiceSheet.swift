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
    /// Pre-picks the sample language — the new-language prompt already knows
    /// the recording is meant for one language in particular.
    var presetLanguageCode: String? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var recorder = VoiceRecorder()
    @State private var name = ""
    @State private var cloning = false
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var zoom = 1.0
    @State private var playhead = 0.0
    @State private var playAnchor = 0.0
    @State private var languageCode = Language.english.code
    @State private var preview = SamplePreviewPlayer()
    @State private var voicePreview = SamplePreviewPlayer()
    @State private var voicePreviewPhase = VoicePreviewPhase.idle
    @State private var voicePreviewTask: Task<Void, Never>?
    @State private var previewText = PreviewPassages.passage(for: .english)

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
        .onAppear {
            if let presetLanguageCode {
                languageCode = presetLanguageCode
                previewText = PreviewPassages.passage(for: .named(presetLanguageCode))
            }
        }
        .onChange(of: languageCode) {
            previewText = PreviewPassages.passage(for: .named(languageCode))
            invalidateVoicePreview()
        }
        .onDisappear {
            preview.stop()
            voicePreview.stop()
            voicePreviewTask?.cancel()
        }
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
            HStack(spacing: Palette.Space.sm) {
                Text(recorder.sourceName ?? "Your recording")
                    .font(.huiverCaption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    zoom = max(1, zoom / 2)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= 1)
                .help("Zoom out")
                Button {
                    zoom = min(maximumZoom, zoom * 2)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= maximumZoom)
                .help("Zoom in on the selection")
                Button(preview.playing ? "Pause" : "Play", systemImage: preview.playing ? "pause.fill" : "play.fill") {
                    togglePreview()
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
                windowStart: window.lowerBound,
                windowEnd: window.upperBound,
                playhead: displayedPlayhead,
                onScrub: { seconds in
                    preview.stop()
                    playhead = min(max(seconds, trimStart), trimEnd)
                },
                tint: theme.colors.primary,
                muted: theme.colors.mutedForeground
            )
            .frame(height: 104)
            .onChange(of: trimStart) {
                preview.stop()
                playhead = min(max(playhead, trimStart), trimEnd)
                invalidateVoicePreview()
            }
            .onChange(of: trimEnd) {
                preview.stop()
                playhead = min(max(playhead, trimStart), trimEnd)
                invalidateVoicePreview()
            }

            HStack {
                Text(time(trimStart))
                Spacer()
                Text(
                    zoom > 1
                        ? "Showing \(time(window.lowerBound)) – \(time(window.upperBound))"
                        : "Drag the handles to choose the clearest section"
                )
                Spacer()
                Text(time(trimEnd))
            }
            .font(.huiverCaption.monospacedDigit())
            .foregroundStyle(theme.colors.mutedForeground)

            voicePreviewRow
        }
    }

    /// The cloned-voice preview: rendered from the current selection on
    /// request, so the trim can be judged by ear before anything is saved.
    @ViewBuilder
    private var voicePreviewRow: some View {
        VStack(alignment: .leading, spacing: Palette.Space.xs) {
            Text("Preview text — \(Language.named(languageCode).name)")
                .font(.huiverCaption.weight(.semibold))
            TextField("What the preview should say", text: $previewText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .font(.huiverCaption)
                .onChange(of: previewText) { invalidateVoicePreview() }

            HStack(spacing: Palette.Space.sm) {
                Button("Render voice preview", systemImage: "waveform") {
                    renderVoicePreview()
                }
                .disabled(
                    !isUsable || voicePreviewPhase == .rendering
                        || previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                switch voicePreviewPhase {
                case .idle:
                    Text("Hear this selection read the text above, before saving anything")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                case .rendering:
                    ProgressView().controlSize(.small)
                    Text("Rendering with this selection…")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.mutedForeground)
                case .ready(let rendered):
                    Button(
                        voicePreview.playing ? "Stop" : "Play",
                        systemImage: voicePreview.playing ? "stop.fill" : "speaker.wave.2.fill"
                    ) {
                        preview.stop()
                        voicePreview.toggle(rendered)
                    }
                case .failed(let message):
                    Text("Voice preview failed: \(message)")
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.destructive)
                }
            }
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

    private var selectedSamples: [Float] { samples(from: trimStart, to: trimEnd) }

    private func samples(from: Double, to: Double) -> [Float] {
        let rate = Double(ReferenceClip.sampleRate)
        let lower = min(recorder.samples.count, max(0, Int(from * rate)))
        let upper = min(recorder.samples.count, max(lower, Int(to * rate)))
        return Array(recorder.samples[lower..<upper])
    }

    private var selectedChoice: ReferenceClip.Choice? {
        selectedSamples.isEmpty ? nil : ReferenceClip.prepare(selectedSamples)
    }

    /// Zooming past the point where the selection fills the view stops being
    /// useful for placing the handles, so the ceiling follows the selection.
    private var maximumZoom: Double {
        guard recorder.seconds > 0 else { return 1 }
        return min(64, max(1, recorder.seconds / max(selectedDuration * 1.2, 0.5)))
    }

    /// The visible slice of the timeline, centred on the selection.
    private var window: ClosedRange<Double> {
        let total = max(recorder.seconds, 0.001)
        let span = total / min(max(zoom, 1), maximumZoom)
        let center = (trimStart + trimEnd) / 2
        let start = min(max(0, center - span / 2), total - span)
        return start...(start + span)
    }

    /// The line the person sees: the live position while playing, the chosen
    /// start point otherwise.
    private var displayedPlayhead: Double {
        preview.playing ? min(trimEnd, playAnchor + preview.elapsed) : playhead
    }

    private func togglePreview() {
        if preview.playing {
            playhead = min(trimEnd, playAnchor + preview.elapsed)
            preview.stop()
            return
        }
        voicePreview.stop()
        let from = playhead >= trimEnd - 0.05 ? trimStart : min(max(playhead, trimStart), trimEnd)
        playhead = from
        playAnchor = from
        preview.toggle(samples(from: from, to: trimEnd))
    }

    /// Throw away any rendered preview: the selection or text it was made from
    /// has changed, so it no longer says what playing it would claim.
    private func invalidateVoicePreview() {
        voicePreviewTask?.cancel()
        voicePreview.stop()
        voicePreviewPhase = .idle
    }

    /// Render the preview text with a voice cloned from the current selection.
    private func renderVoicePreview() {
        invalidateVoicePreview()
        guard isUsable else { return }
        voicePreviewPhase = .rendering
        let samples = selectedSamples
        let language = Language.named(languageCode)
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        let flag = CancelFlag()
        voicePreviewTask = Task {
            do {
                let rendered = try await withTaskCancellationHandler {
                    try await model.previewClonedSpeech(
                        from: samples,
                        text: text,
                        language: language,
                        cancelled: { flag.isCancelled }
                    )
                } onCancel: {
                    flag.cancel()
                }
                guard !Task.isCancelled else { return }
                voicePreviewPhase = .ready(rendered)
            } catch {
                guard !Task.isCancelled else { return }
                voicePreviewPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func resetTrim() {
        trimStart = 0
        trimEnd = recorder.seconds
        playhead = 0
        playAnchor = 0
        zoom = 1
        invalidateVoicePreview()
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
    /// Seconds of audio rendered since the last `play`, ticked while playing
    /// so the view can move its playhead.
    private(set) var elapsed = 0.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var ticker: Timer?

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
            elapsed = 0
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        node.stop()
        engine.stop()
        playing = false
    }

    private func tick() {
        guard playing, let nodeTime = node.lastRenderTime,
              let time = node.playerTime(forNodeTime: nodeTime)
        else { return }
        elapsed = max(0, Double(time.sampleTime) / time.sampleRate)
    }

    private func finished() {
        guard playing else { return }
        ticker?.invalidate()
        ticker = nil
        engine.stop()
        playing = false
    }
}

/// A compact SoundCloud-style overview with independently draggable in/out
/// points, a zoomable viewport, and a draggable playhead line.
private struct WaveformTrimmer: View {
    let samples: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// The visible slice of the timeline; equals `0...duration` when unzoomed.
    let windowStart: Double
    let windowEnd: Double
    /// Where playback stands or would begin, in full-timeline seconds.
    let playhead: Double
    /// Called with the new playhead time while the line is being dragged.
    let onScrub: (Double) -> Void
    let tint: Color
    let muted: Color

    private let bars = 110
    private let minimumSelection = 0.5

    /// The playhead acts as a wall while a handle drags towards it, captured
    /// once per drag: a handle parked against the wall does not burst through
    /// it on the next tick. A handle that starts *on* the playhead pushes it
    /// along instead — otherwise the start handle could never leave zero.
    @State private var handleWall: Double?
    @State private var draggingHandle = false

    private var windowSpan: Double { max(windowEnd - windowStart, 0.001) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let left = x(for: start, in: width)
            let right = x(for: end, in: width)

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

                Rectangle().fill(Color.black.opacity(0.38))
                    .frame(width: min(max(0, left), width))
                Rectangle().fill(Color.black.opacity(0.38))
                    .frame(width: max(0, width - min(max(0, right), width)))
                    .offset(x: min(max(0, right), width))

                if left > -11, left < width + 11 {
                    handle(at: left, width: width, isStart: true)
                }
                if right > -11, right < width + 11 {
                    handle(at: right, width: width, isStart: false)
                }
                playheadLine(width: width, height: geometry.size.height)
            }
            .coordinateSpace(name: "waveform")
            .background(muted.opacity(0.12), in: .rect(cornerRadius: Palette.Radius.md))
            .clipShape(.rect(cornerRadius: Palette.Radius.md))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio trim range")
        .accessibilityValue("From \(time(start)) to \(time(end))")
    }

    private func x(for seconds: Double, in width: CGFloat) -> CGFloat {
        width * CGFloat((seconds - windowStart) / windowSpan)
    }

    private func seconds(atX x: CGFloat, in width: CGFloat) -> Double {
        windowStart + Double(min(max(0, x), width) / width) * windowSpan
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
                DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform"))
                    .onChanged { value in
                        if !draggingHandle {
                            draggingHandle = true
                            handleWall = isStart
                                ? (playhead > start + 0.01 ? playhead : nil)
                                : (playhead < end - 0.01 ? playhead : nil)
                        }
                        let at = seconds(atX: value.location.x, in: width)
                        if isStart {
                            var limit = end - minimumSelection
                            if let handleWall { limit = min(limit, handleWall) }
                            start = min(max(0, at), limit)
                        } else {
                            var floor = start + minimumSelection
                            if let handleWall { floor = max(floor, handleWall) }
                            end = max(min(duration, at), floor)
                        }
                    }
                    .onEnded { _ in
                        draggingHandle = false
                        handleWall = nil
                    }
            )
    }

    @ViewBuilder
    private func playheadLine(width: CGFloat, height: CGFloat) -> some View {
        let x = x(for: playhead, in: width)
        if x > -8, x < width + 8 {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
            .frame(width: 16)
            .contentShape(Rectangle())
            .offset(x: min(max(-8, x - 8), width - 8))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("waveform")).onChanged { value in
                    onScrub(seconds(atX: value.location.x, in: width))
                }
            )
            .accessibilityHidden(true)
        }
    }

    /// Peaks for the visible window only, normalised against the whole take so
    /// the waveform keeps its shape while zooming.
    private var peaks: [Float] {
        guard !samples.isEmpty, duration > 0 else { return [Float](repeating: 0.05, count: bars) }
        let lower = min(samples.count, max(0, Int(Double(samples.count) * windowStart / duration)))
        let upper = min(samples.count, max(lower, Int(Double(samples.count) * windowEnd / duration)))
        let count = upper - lower
        guard count > 0 else { return [Float](repeating: 0.05, count: bars) }

        let stride = max(1, count / bars)
        var result: [Float] = []
        result.reserveCapacity(bars)
        for bar in 0..<bars {
            let barLower = min(upper, lower + bar * stride)
            let barUpper = min(upper, barLower + stride)
            let sampling = max(1, stride / 100)
            var peak: Float = 0
            var index = barLower
            while index < barUpper {
                peak = max(peak, abs(samples[index]))
                index += sampling
            }
            result.append(max(0.04, peak))
        }

        let globalSampling = max(1, samples.count / (bars * 100))
        var maximum: Float = 0.001
        var index = 0
        while index < samples.count {
            maximum = max(maximum, abs(samples[index]))
            index += globalSampling
        }
        return result.map { min(1, $0 / maximum) }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d minutes %.1f seconds", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// Where the rendered voice preview stands for the current selection.
private enum VoicePreviewPhase: Equatable {
    case idle
    case rendering
    case ready([Float])
    case failed(String)
}

/// A flag the engine's token loop can consult from off the main actor.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func cancel() {
        lock.lock()
        flagged = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}

/// One short passage per engine language, so the preview reads in the language
/// the sample is meant for. The sentences are the same everywhere: calm,
/// ordinary prose that shows pacing rather than vocabulary.
private enum PreviewPassages {
    static func passage(for language: Language) -> String {
        byCode[language.code] ?? byCode["en"]!
    }

    private static let byCode: [String: String] = [
        "ar": "سقط ضوء الصباح بهدوء على الماء، واستيقظت المدينة ببطء. قرأتُ بضع صفحات قبل أن تجهز القهوة.",
        "zh": "清晨的光轻轻落在水面上，小镇慢慢醒来。咖啡煮好之前，我读了几页书。",
        "da": "Morgenlyset faldt blidt på vandet, og byen vågnede langsomt. Jeg læste et par sider, før kaffen var klar.",
        "nl": "Het ochtendlicht viel zacht op het water en de stad werd langzaam wakker. Ik las een paar bladzijden voordat de koffie klaar was.",
        "en": "The morning light fell softly on the water, and the town woke slowly. I read a few pages before the coffee was ready.",
        "fi": "Aamun valo lankesi pehmeästi veteen, ja kaupunki heräsi hitaasti. Luin muutaman sivun ennen kuin kahvi oli valmista.",
        "fr": "La lumière du matin tombait doucement sur l'eau, et la ville s'éveillait lentement. J'ai lu quelques pages avant que le café soit prêt.",
        "de": "Das Morgenlicht fiel sanft auf das Wasser, und die Stadt erwachte langsam. Ich las ein paar Seiten, bevor der Kaffee fertig war.",
        "el": "Το πρωινό φως έπεφτε απαλά στο νερό και η πόλη ξυπνούσε αργά. Διάβασα μερικές σελίδες πριν ετοιμαστεί ο καφές.",
        "he": "אור הבוקר נפל ברכות על המים, והעיר התעוררה לאט. קראתי כמה עמודים לפני שהקפה היה מוכן.",
        "hi": "सुबह की रोशनी पानी पर धीरे से पड़ी, और शहर धीरे-धीरे जागा। कॉफ़ी तैयार होने से पहले मैंने कुछ पन्ने पढ़े।",
        "it": "La luce del mattino cadeva dolcemente sull'acqua e la città si svegliava lentamente. Ho letto qualche pagina prima che il caffè fosse pronto.",
        "ja": "朝の光が水面にやわらかく落ち、町はゆっくりと目を覚ました。コーヒーができる前に、数ページ読んだ。",
        "ko": "아침 햇살이 물 위에 부드럽게 내려앉고, 마을은 천천히 깨어났다. 커피가 준비되기 전에 몇 쪽을 읽었다.",
        "ms": "Cahaya pagi jatuh lembut ke atas air, dan bandar itu bangun perlahan-lahan. Saya membaca beberapa halaman sebelum kopi siap.",
        "no": "Morgenlyset falt mykt på vannet, og byen våknet langsomt. Jeg leste noen sider før kaffen var klar.",
        "pl": "Poranne światło łagodnie padało na wodę, a miasto budziło się powoli. Przeczytałem kilka stron, zanim kawa była gotowa.",
        "pt": "A luz da manhã caía suavemente sobre a água, e a cidade acordava devagar. Li algumas páginas antes de o café ficar pronto.",
        "ru": "Утренний свет мягко ложился на воду, и город медленно просыпался. Я прочитал несколько страниц, пока варился кофе.",
        "es": "La luz de la mañana caía suavemente sobre el agua y el pueblo despertaba despacio. Leí unas páginas antes de que el café estuviera listo.",
        "sw": "Mwanga wa asubuhi ulianguka taratibu juu ya maji, na mji ukaamka polepole. Nilisoma kurasa chache kabla kahawa haijawa tayari.",
        "sv": "Morgonljuset föll mjukt på vattnet och staden vaknade långsamt. Jag läste några sidor innan kaffet var klart.",
        "tr": "Sabah ışığı suya usulca düşüyordu ve kasaba yavaşça uyanıyordu. Kahve hazır olmadan önce birkaç sayfa okudum.",
    ]
}
