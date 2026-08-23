import SwiftUI

/// The Settings entrance to `VoiceRecordingFlow`: a sheet that clones the
/// take right away and dismisses when the voice exists.
struct RecordVoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = VoiceRecorder()
    @State private var cloning = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.colors.background.ignoresSafeArea()
                ScrollView {
                    VoiceRecordingFlow(
                        recorder: recorder,
                        submitLabel: "Create voice",
                        busy: cloning,
                        failure: failure
                    ) { samples, name in
                        create(samples: samples, name: name)
                    }
                    .padding(Palette.Space.lg)
                }
            }
            .navigationTitle("Your voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.reset()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(recorder.state == .recording || cloning)
        }
    }

    private func create(samples: [Float], name: String) {
        guard !cloning else { return }
        cloning = true
        failure = nil
        Task {
            defer { cloning = false }
            do {
                // English because Nano is: the roster it joins is the one the
                // engine reports, and it reports one language.
                _ = try await model.cloneVoice(
                    from: samples,
                    name: name,
                    language: model.engineLanguages.first ?? .english
                )
                recorder.reset()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
