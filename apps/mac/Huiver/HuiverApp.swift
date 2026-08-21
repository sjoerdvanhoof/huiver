import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @State private var sync = MacSyncModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(sync)
                .huiverTheme()
                .task {
                    await model.load()
                    // After the library exists: an inbound sync session reads
                    // straight out of it.
                    sync.startAdvertising(model: model)
                }
                .onChange(of: phase) { _, new in
                    // The position ticker writes lazily, and quitting from the
                    // Dock is the usual way this app ends. Write it down while
                    // there is still a process to write it from. Receding is
                    // also the moment to hand back idle GPU memory — the check
                    // inside leaves a render still running alone.
                    if new == .background {
                        model.narrator?.checkpoint()
                        model.trimEngineMemoryIfIdle()
                    }
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands { playbackCommands }
    }

    /// Transport as menu items, which on a Mac is what makes it keyboard
    /// transport. The shortcuts follow Music's: ⌘→ and ⌘← move between
    /// chapters, with ⌥ for the small skips inside one.
    @CommandsBuilder
    private var playbackCommands: some Commands {
        CommandMenu("Playback") {
            let narrator = model.narrator
            let playing = narrator?.chapterId != nil

            Button(narrator?.state == .speaking ? "Pause" : "Play") {
                narrator?.toggle()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!playing || narrator?.state == .preparing)

            Divider()

            Button("Back 15 Seconds") { narrator?.skip(by: -15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!playing)
            Button("Forward 30 Seconds") { narrator?.skip(by: 30) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!playing)

            Divider()

            Button("Previous Chapter") { narrator?.changeChapter(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!(narrator?.hasPreviousChapter ?? false))
            Button("Next Chapter") { narrator?.changeChapter(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!(narrator?.hasNextChapter ?? false))

            Divider()

            Button("Stop") { narrator?.stop() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!playing)
        }
    }
}
