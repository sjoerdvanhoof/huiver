import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    /// Plays the bundled samples. `AVAudioPlayer` rather than the engine: these
    /// are finished files, and auditioning a voice should not wake the model.
    @State private var preview = PreviewPlayer()

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                ForEach(model.voices) { voice in
                    HStack(spacing: Palette.Space.md) {
                        if let url = voice.previewURL {
                            Button {
                                preview.toggle(url, id: voice.id)
                            } label: {
                                Image(systemName: preview.playing == voice.id
                                    ? "stop.circle.fill" : "play.circle")
                                    .font(.title2)
                                    .foregroundStyle(theme.colors.primary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // No sample shipped for this voice yet.
                            Image(systemName: "play.circle")
                                .font(.title2)
                                .foregroundStyle(theme.colors.border)
                        }

                        Button {
                            model.selectedVoiceId = voice.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name).foregroundStyle(.primary)
                                    Text(voice.detail).font(.caption).foregroundStyle(.secondary)
                                    // Only for the voice in use: ten paragraphs
                                    // of prose would turn the picker into an
                                    // essay to scroll past.
                                    if let persona = voice.persona,
                                       model.selectedVoiceId == voice.id {
                                        Text(persona)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 2)
                                    }
                                }
                                Spacer()
                                if model.selectedVoiceId == voice.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Chatterbox has no voice roster — it clones a reference recording. These were cloned on your Mac and shipped with the app; changing voice re-renders a chapter rather than mixing two narrators. Samples are pre-rendered, so they play instantly instead of waking the model.")
            }

            Section {
                LabeledContent("Temperature", value: String(format: "%.2f", model.options.temperature))
                Slider(value: $model.options.temperature, in: 0.4...1.2, step: 0.05)
                LabeledContent("Top-p", value: String(format: "%.2f", model.options.topP))
                Slider(value: $model.options.topP, in: 0.5...1.0, step: 0.01)
                LabeledContent(
                    "Repetition penalty",
                    value: String(format: "%.2f", model.options.repetitionPenalty)
                )
                Slider(value: $model.options.repetitionPenalty, in: 1.0...2.0, step: 0.05)
            } header: {
                Text("Sampling")
            } footer: {
                Text("Lower the temperature for a long book and it reads more evenly, at the cost of some life. There is no speed control: the model has none, so change playback speed in the player instead.")
            }

            Section {
                NavigationLink {
                    QueueView()
                } label: {
                    LabeledContent("Queued", value: queueSummary)
                }
            } header: {
                Text("Conversion")
            } footer: {
                Text("Conversion runs while huiver is open. iOS suspends apps that leave the screen, and it offers no way to keep computing in the background — so leaving mid-chapter finishes the sentence being worked on and stops there. Coming back picks up exactly where it left off, without pressing convert again, even after a force quit. Listening does keep going off screen, because then the app really is playing audio.")
            }

            Section {
                LabeledContent("Books", value: "\(model.books.count)")
                LabeledContent("Audio on disk", value: size(model.bytesOnDisk))
                Toggle("Clean up finished chapters", isOn: cleanupBinding)
            } header: {
                Text("Storage")
            } footer: {
                Text("An hour of audio is about 170 MB. A chapter you have listened all the way through has its audio removed a week later — the text always stays, and rendering it again brings the audio back. Whatever is playing or waiting to convert is left alone.")
            }

            if !model.placement.isEmpty {
                Section {
                    ForEach(model.placement.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        LabeledContent(entry.key, value: entry.value)
                    }
                } header: {
                    Text("Where the models run")
                } footer: {
                    Text("Core ML picks this per model and per device. Anything that fell back to CPU is a good place to look if synthesis is slower than you expected.")
                }
            }

            if let failure = model.loadFailure {
                Section("Engine") {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .onDisappear { preview.stop() }
    }

    /// `autoCleanup` lives in UserDefaults rather than in observable state, so
    /// it needs a binding written out rather than `@Bindable`'s.
    private var cleanupBinding: Binding<Bool> {
        .init(get: { model.autoCleanup }, set: { model.autoCleanup = $0 })
    }

    private var queueSummary: String {
        guard let converter = model.converter else { return "—" }
        let waiting = converter.queue.count
        if waiting == 0 { return "nothing" }
        return converter.isBusy ? "\(waiting) chapter\(waiting == 1 ? "" : "s")" : "\(waiting) paused"
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


/// Plays the bundled voice samples, one at a time.
@MainActor
@Observable
final class PreviewPlayer {
    /// Which voice is sounding, so its button can show as stop.
    private(set) var playing: String?

    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    func toggle(_ url: URL, id: String) {
        if playing == id {
            stop()
            return
        }
        stop()
        do {
            #if os(iOS)
            // `.playback` so a sample is audible with the ringer switch set to
            // silent, which is where a phone usually is.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            self.player = player
            playing = id

            // No delegate: a timer that outlives the sample by a moment is
            // enough to put the button back, and avoids an @objc shim.
            let seconds = player.duration + 0.1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, playing == id else { return }
                stop()
            }
        } catch {
            playing = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}
