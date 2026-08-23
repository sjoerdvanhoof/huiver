import AVFoundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    /// Plays the bundled samples. `AVAudioPlayer` rather than the engine: these
    /// are finished files, and auditioning a voice should not wake the model.
    @State private var preview = PreviewPlayer()
    /// A voice picked while the phone holds audio read by someone else, held
    /// until the switch is confirmed — changing narrator re-renders those
    /// chapters, which is hours of compute worth a sentence of warning.
    @State private var pendingVoice: Voice?
    /// Local mirrors of the UserDefaults-backed skip sizes: pickers need a
    /// value that view updates can observe.
    @State private var skipBack = SkipIntervals.backward
    @State private var skipForward = SkipIntervals.forward

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                ForEach(model.voices) { voice in
                    HStack(spacing: Palette.Space.md) {
                        if let url = voice.previewURL {
                            Button {
                                // One narrator at a time: auditioning over a
                                // playing book gave two voices at once.
                                if model.narrator?.state == .speaking {
                                    model.narrator?.pause()
                                }
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
                            select(voice)
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
                Picker("Skip back", selection: $skipBack) {
                    ForEach(SkipIntervals.backwardChoices, id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
                Picker("Skip forward", selection: $skipForward) {
                    ForEach(SkipIntervals.forwardChoices, id: \.self) {
                        Text("\(Int($0)) seconds").tag($0)
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("The transport buttons everywhere — player, mini player, lock screen. The lock screen picks the new sizes up at the next launch.")
            }
            .onChange(of: skipBack) { _, new in SkipIntervals.backward = new }
            .onChange(of: skipForward) { _, new in SkipIntervals.forward = new }

            ConnectorSection()

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

            Section {
                Button("Copy diagnostics") {
                    let url = URL.documentsDirectory.appendingPathComponent("playback.log")
                    UIPasteboard.general.string =
                        (try? String(contentsOf: url, encoding: .utf8)) ?? "The log is empty."
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The playback log — what the player, the lock screen and sync were doing, with timestamps. Paste it into a message when something misbehaves; it contains no book text.")
            }

            if let failure = model.loadFailure {
                Section("Engine") {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refresh()
            // The full audio-tree walk, done when this screen asks for it
            // rather than on the converter's every chunk.
            await model.refreshStorage()
        }
        .onDisappear { preview.stop() }
        .confirmationDialog(
            "Change the voice to \(pendingVoice?.name ?? "")?",
            isPresented: .init(
                get: { pendingVoice != nil },
                set: { if !$0 { pendingVoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Change voice") {
                if let voice = pendingVoice { model.selectedVoiceId = voice.id }
                pendingVoice = nil
            }
            Button("Cancel", role: .cancel) { pendingVoice = nil }
        } message: {
            Text(
                "\(renderedByOthers(than: pendingVoice)) rendered chapter(s) were read "
                    + "by another voice. Their audio stays playable as it is — "
                    + "\"Render again\" on a chapter is how you have one re-read in the "
                    + "new voice."
            )
        }
    }

    /// Switch immediately when nothing rendered is affected; otherwise say
    /// what the change means first.
    private func select(_ voice: Voice) {
        guard voice.id != model.selectedVoiceId else { return }
        if renderedByOthers(than: voice) > 0 {
            pendingVoice = voice
        } else {
            model.selectedVoiceId = voice.id
        }
    }

    /// How many chapters on the phone hold audio in a voice other than this one.
    private func renderedByOthers(than voice: Voice?) -> Int {
        guard let voice else { return 0 }
        return model.books.reduce(0) { total, book in
            total + book.chapters.filter {
                $0.renderedChunks > 0 && $0.renderedVoice != nil && $0.renderedVoice != voice.id
            }.count
        }
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
            // silent, which is where a phone usually is. The narrator's own
            // configuration — spoken audio, long-form — is kept when it is
            // already in place: overwriting it with `.default` left the whole
            // session in the wrong mode for the rest of the listen.
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            }
            try session.setActive(true)
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
