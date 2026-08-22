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

    @State private var recording = false
    /// A voice picked while the shelf holds audio read by someone else, held
    /// until the switch is confirmed — changing narrator re-renders those
    /// chapters, which is hours of compute worth a sentence of warning.
    @State private var pendingVoice: Voice?

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
                            select(voice)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Palette.Space.xs) {
                                        Text(voice.name).foregroundStyle(.primary)
                                        // The language the clip was recorded
                                        // in, which is the language this voice
                                        // has an accent for.
                                        if let code = voice.language {
                                            Text(Language.named(code).name)
                                                .font(.caption2)
                                                .foregroundStyle(theme.colors.mutedForeground)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(
                                                    theme.colors.muted, in: .capsule
                                                )
                                        }
                                    }
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
                                if model.isRecorded(voice) {
                                    Button {
                                        model.deleteVoice(voice)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(theme.colors.mutedForeground)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete this recorded voice")
                                }
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
                Button("Record a voice", systemImage: "mic") { recording = true }
                    .disabled(!model.canCloneVoices)
            } footer: {
                Text(model.canCloneVoices
                    ? "Fifteen seconds of your own reading becomes a voice that can read any "
                        + "book. The recording is used once and not kept — what is stored is a "
                        + "set of numbers that cannot be turned back into audio."
                    : "Cloning needs the multilingual models. Export them with bun run mac:models "
                        + "and install them with bun run mac:install.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $recording) { RecordVoiceSheet() }
        .navigationTitle("Voices")
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
        } message: {
            Text(
                "\(renderedByOthers(than: pendingVoice)) rendered chapter(s) were read "
                    + "by another voice. Their audio stays playable as it is; playing or "
                    + "converting one again re-renders it in the new voice."
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

    /// How many chapters on the shelf hold audio in a voice other than this one.
    private func renderedByOthers(than voice: Voice?) -> Int {
        guard let voice else { return 0 }
        return model.books.reduce(0) { total, book in
            total + book.chapters.filter {
                $0.renderedChunks > 0 && $0.renderedVoice != nil && $0.renderedVoice != voice.id
            }.count
        }
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
