import AppKit
import SwiftUI

/// Sampling, storage and where the models landed — the parts of the iOS
/// Settings screen that make sense on a Mac. Voices have a sidebar entry of
/// their own here, so they are not repeated.
struct SettingsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    /// Local mirrors of the UserDefaults-backed skip sizes: pickers need a
    /// value that view updates can observe.
    @State private var skipBack = SkipIntervals.backward
    @State private var skipForward = SkipIntervals.forward

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                LabeledContent("Engine", value: model.engineName)
                LabeledContent(
                    "Languages",
                    value: model.engineLanguages.count == 1
                        ? model.engineLanguages[0].name
                        : "\(model.engineLanguages.count) languages"
                )
            } header: {
                Text("Model")
            } footer: {
                Text("The multilingual model reads every language above, and computes two passes per token — a guided one and an unguided one — which is why it belongs on the Mac rather than the phone. Chinese, Japanese, Hebrew, Korean and Russian are missing because each needs its own text preparation, which this app does not do.")
            }

            Section {
                LabeledContent("Temperature", value: String(format: "%.2f", model.options.temperature))
                Slider(value: $model.options.temperature, in: 0.4...1.2, step: 0.05)
                LabeledContent("Top-p", value: String(format: "%.2f", model.options.topP))
                Slider(value: $model.options.topP, in: 0.5...1.0, step: 0.01)
                LabeledContent("Min-p", value: String(format: "%.3f", model.options.minP))
                Slider(value: $model.options.minP, in: 0...0.2, step: 0.005)
                LabeledContent(
                    "Guidance", value: String(format: "%.2f", model.options.cfgWeight)
                )
                Slider(value: $model.options.cfgWeight, in: 0...1.0, step: 0.05)
                LabeledContent(
                    "Expression", value: String(format: "%.2f", model.options.exaggeration)
                )
                Slider(value: $model.options.exaggeration, in: 0.25...1.0, step: 0.05)
                LabeledContent(
                    "Repetition penalty",
                    value: String(format: "%.2f", model.options.repetitionPenalty)
                )
                Slider(value: $model.options.repetitionPenalty, in: 1.0...2.0, step: 0.05)
            } header: {
                Text("Sampling")
            } footer: {
                Text("Lower the temperature for a long book and it reads more evenly, at the cost of some life. Guidance is how hard the model is pushed towards the text — past about 0.7 it starts to sound clipped. There is no speed control: the model has none, so change playback speed in the player instead.")
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
                Text("The transport buttons everywhere — player, mini player, menu bar. Control Centre picks the new sizes up at the next launch.")
            }
            .onChange(of: skipBack) { _, new in SkipIntervals.backward = new }
            .onChange(of: skipForward) { _, new in SkipIntervals.forward = new }

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
                    Text("Core ML picks this per model and per machine. Anything that fell back to CPU is a good place to look if synthesis is slower than you expected.")
                }
            }

            Section {
                Button("Copy diagnostics") {
                    let url = URL.documentsDirectory.appendingPathComponent("playback.log")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        (try? String(contentsOf: url, encoding: .utf8)) ?? "The log is empty.",
                        forType: .string
                    )
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The playback log — what the player, the media keys and sync were doing, with timestamps. Paste it into a message when something misbehaves; it contains no book text.")
            }

            if let failure = model.loadFailure {
                Section("Engine") {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            await model.refresh()
            // The full audio-tree walk, done when this pane asks for it
            // rather than on the converter's every chunk.
            await model.refreshStorage()
        }
    }

    /// `autoCleanup` lives in UserDefaults rather than in observable state, so
    /// it needs a binding written out rather than `@Bindable`'s.
    private var cleanupBinding: Binding<Bool> {
        .init(get: { model.autoCleanup }, set: { model.autoCleanup = $0 })
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
