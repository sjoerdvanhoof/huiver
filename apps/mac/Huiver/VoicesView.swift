import AVFoundation
import SwiftUI

/// The voice roster: audition, pick, and — later — record.
///
/// Voices are cloned on this Mac by the export tooling and shipped with the
/// app; recording one from here is where that pipeline is headed, so the
/// button already has a seat at the table.
struct VoicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    /// Plays the bundled samples. `AVAudioPlayer` rather than the engine: these
    /// are finished files, and auditioning a voice should not wake the model.
    @State private var preview = PreviewPlayer()

    var body: some View {
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
                Text("Chatterbox has no voice roster — it clones a reference recording. Changing voice re-renders a chapter rather than mixing two narrators. Samples are pre-rendered, so they play instantly instead of waking the model.")
            }

            Section {
                Button("Record a voice", systemImage: "mic") {}
                    .disabled(true)
            } footer: {
                Text("Voice recording arrives with a later update.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voices")
        .onDisappear { preview.stop() }
    }
}

/// Plays the bundled voice samples, one at a time.
@MainActor
@Observable
final class PreviewPlayer {
    /// Which voice is sounding, so its button can show as stop.
    private(set) var playing: String?

    private var player: AVAudioPlayer?

    func toggle(_ url: URL, id: String) {
        if playing == id {
            stop()
            return
        }
        stop()
        do {
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
