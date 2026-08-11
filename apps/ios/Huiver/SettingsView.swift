import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                ForEach(model.voices) { voice in
                    Button {
                        model.selectedVoiceId = voice.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.name).foregroundStyle(.primary)
                                Text(voice.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.selectedVoiceId == voice.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Chatterbox has no voice roster — it clones a reference recording. These were cloned on your Mac and shipped with the app; changing voice re-renders a chapter rather than mixing two narrators.")
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
                LabeledContent("Queued", value: queueSummary)
            } header: {
                Text("Conversion")
            } footer: {
                Text("Conversion runs while huiver is open. iOS suspends apps that leave the screen, and it offers no way to keep computing in the background — so leaving mid-chapter finishes the sentence being worked on and stops there. Coming back picks up exactly where it left off, without pressing convert again, even after a force quit. Listening does keep going off screen, because then the app really is playing audio.")
            }

            Section("Storage") {
                LabeledContent("Books", value: "\(model.books.count)")
                LabeledContent("Audio on disk", value: size(model.bytesOnDisk))
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
