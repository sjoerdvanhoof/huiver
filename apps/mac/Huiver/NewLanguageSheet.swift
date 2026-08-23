import SwiftUI

/// A book just arrived in a language nobody has picked a voice for.
///
/// Asked once per language, at the moment it becomes real — a Polish book on
/// the shelf — rather than up front for all eighteen. Picking a voice adds
/// the language to the preferred list; "Not now" leaves everything alone and
/// the book falls back to the first reader recorded in its language.
struct NewLanguageSheet: View {
    let prompt: AppModel.NewLanguagePrompt

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var preview = PreviewPlayer()
    @State private var chosenId: String?
    /// Swaps the picker for the recorder in place — a sheet over a sheet is
    /// where macOS stops feeling like macOS.
    @State private var isRecording = false

    private var language: Language { prompt.language }
    private var candidates: [Voice] {
        model.voices.filter { $0.language == language.code }
    }
    private var chosen: Voice? {
        candidates.first { $0.id == chosenId } ?? candidates.first
    }

    var body: some View {
        if isRecording {
            VStack(alignment: .leading, spacing: 0) {
                VoiceCaptureView(
                    onDone: { voice in
                        model.setPreferredVoice(voice.id, for: language.code)
                        dismiss()
                    },
                    onCancel: { isRecording = false },
                    presetLanguageCode: language.code
                )
            }
        } else {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            VStack(alignment: .leading, spacing: Palette.Space.xs) {
                Text("A book in \(language.name)")
                    .font(.huiverTitle)
                    .foregroundStyle(theme.colors.foreground)
                Text("“\(prompt.bookTitle)” is the first \(language.name) book on this shelf. Choose the voice that should read \(language.name) — the accent comes from the voice's own recording, so a native reader sounds native.")
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }

            if candidates.isEmpty {
                Text("No voice has been recorded in \(language.name) yet. Record one, or the app voice will read it with its own accent.")
                    .font(.huiverBody)
                    .foregroundStyle(theme.colors.mutedForeground)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { voice in
                        voiceRow(voice)
                        if voice.id != candidates.last?.id {
                            Divider().overlay(theme.colors.border)
                        }
                    }
                }
                .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
            }

            HStack(spacing: Palette.Space.md) {
                if model.canCloneVoices {
                    Button("Record my voice in \(language.name)…", systemImage: "mic") {
                        preview.stop()
                        isRecording = true
                    }
                }
                Spacer()
                Button("Not now") { dismiss() }
                if let chosen {
                    Button("Use \(chosen.name)") {
                        model.setPreferredVoice(chosen.id, for: language.code)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Palette.Space.xl)
        .frame(width: 520)
        .onDisappear { preview.stop() }
    }

    private func voiceRow(_ voice: Voice) -> some View {
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
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(theme.colors.border)
            }

            Button {
                chosenId = voice.id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).foregroundStyle(theme.colors.foreground)
                        Text(voice.detail)
                            .font(.huiverCaption)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    Spacer()
                    if chosen?.id == voice.id {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(Palette.Space.md)
    }
}
