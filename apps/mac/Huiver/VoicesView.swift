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
            // One section per language the listener reads, each remembering
            // its own narrator — a shelf of English and Dutch books switches
            // between two chosen voices instead of sharing one.
            ForEach(visibleLanguages) { language in
                Section {
                    ForEach(voices(in: language.code)) { voice in
                        voiceRow(voice, chosen: chosenVoiceId(in: language.code))
                    }
                } header: {
                    Text(language.name)
                }
            }

            // Voices whose clip's language nobody wrote down — a voice that
            // arrived over sync, mostly. Never hidden: they cannot earn a
            // section of their own.
            if !languagelessVoices.isEmpty {
                Section {
                    ForEach(languagelessVoices) { voice in
                        voiceRow(voice, chosen: model.selectedVoiceId)
                    }
                } header: {
                    Text("Other voices")
                }
            }

            Section {
                if hiddenVoiceCount > 0 {
                    Menu {
                        ForEach(addableLanguages) { language in
                            Button(language.name) { model.addPreferredLanguage(language.code) }
                        }
                    } label: {
                        Label("Add a language", systemImage: "plus")
                    }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text(
                    "Each language keeps its own narrator — the checkmark in its section is the voice that reads its books. "
                        + (hiddenVoiceCount > 0
                            ? "\(hiddenVoiceCount) voice\(hiddenVoiceCount == 1 ? "" : "s") for languages you do not read are tucked away; add a language to see its reader. "
                            : "")
                        + "Chatterbox has no voice roster — it clones a reference recording. Changing voice re-renders a chapter rather than mixing two narrators."
                )
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
                if let voice = pendingVoice { model.selectVoice(voice) }
                pendingVoice = nil
            }
        } message: {
            Text(
                "\(renderedByOthers(than: pendingVoice)) rendered chapter(s) were read "
                    + "by another voice. Their audio stays playable as it is — "
                    + "\"Render again\" on a chapter is how you have one re-read in the "
                    + "new voice."
            )
        }
    }

    private func voiceRow(_ voice: Voice, chosen: String?) -> some View {
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
                        Text(voice.name).foregroundStyle(.primary)
                        Text(voice.detail).font(.caption).foregroundStyle(.secondary)
                        // Only for the voice in use: ten paragraphs of prose
                        // would turn the picker into an essay to scroll past.
                        if let persona = voice.persona, chosen == voice.id {
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
                    if chosen == voice.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    /// The sections worth drawing: the languages the listener asked for, plus
    /// any a book on the shelf or a recorded voice already lives in — hiding
    /// a language that is plainly in use would just misplace its narrator.
    private var visibleLanguages: [Language] {
        var codes = Set(model.preferredLanguageCodes)
        codes.formUnion(model.books.map(\.languageCode))
        for voice in model.voices where model.isRecorded(voice) {
            if let code = voice.language { codes.insert(code) }
        }
        return Language.all.filter { codes.contains($0.code) }
    }

    private func voices(in languageCode: String) -> [Voice] {
        model.voices.filter { $0.language == languageCode }
    }

    private var languagelessVoices: [Voice] {
        model.voices.filter { $0.language == nil }
    }

    /// The checkmark for one language's section.
    private func chosenVoiceId(in languageCode: String) -> String? {
        model.preferredVoice(for: languageCode)?.id
    }

    private var addableLanguages: [Language] {
        let visible = Set(visibleLanguages.map(\.code))
        return model.selectableLanguages.filter { !visible.contains($0.code) }
    }

    private var hiddenVoiceCount: Int {
        let visible = Set(visibleLanguages.map(\.code))
        return model.voices.filter { voice in
            guard let code = voice.language else { return false }
            return !visible.contains(code)
        }.count
    }

    /// Switch immediately when nothing rendered is affected; otherwise say
    /// what the change means first.
    private func select(_ voice: Voice) {
        if let code = voice.language {
            guard model.preferredVoice(for: code)?.id != voice.id
                || model.selectedVoiceId != voice.id
            else { return }
        } else if voice.id == model.selectedVoiceId {
            return
        }
        if renderedByOthers(than: voice) > 0 {
            pendingVoice = voice
        } else {
            model.selectVoice(voice)
        }
    }

    /// How many chapters would re-render if this voice took over: those whose
    /// audio was read by someone else, in books this voice would actually
    /// read — a new Dutch narrator does not touch the English shelf.
    private func renderedByOthers(than voice: Voice?) -> Int {
        guard let voice else { return 0 }
        return model.books
            .filter { voice.language == nil || $0.languageCode == voice.language }
            .reduce(0) { total, book in
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
