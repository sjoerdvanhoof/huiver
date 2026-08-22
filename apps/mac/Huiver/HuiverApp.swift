import SwiftUI

/// Holds quitting open until the lazy writes are on disk.
///
/// The position ticker and the library index both write on debounce timers, so
/// ⌘Q at the wrong moment lost up to five seconds of each. `terminateLater`
/// is the sanctioned way to finish async work first; the shutdown closure is
/// handed over once the model exists.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (@MainActor () async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @State private var sync = MacSyncModel()
    @Environment(\.scenePhase) private var phase
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(sync)
                .huiverTheme()
                .task {
                    delegate.shutdown = { [weak model] in await model?.shutdown() }
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
                    // Coming forward is the moment to pick an interrupted
                    // render back up — the same bargain the phone makes on
                    // foregrounding, and a no-op when nothing was interrupted.
                    if new == .active {
                        model.narrator?.resumeRendering()
                    }
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            playbackCommands
            // One window is the app. A second one shares every model with the
            // first, and its `.task` used to re-load a gigabyte of models over
            // the running narrator's head — so File gets Open instead of New.
            CommandGroup(replacing: .newItem) {
                Button("Open Book…") { model.wantsImport = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        // ⌘, — the pane is also a sidebar destination, but a Mac app answers
        // the shortcut regardless.
        Settings {
            SettingsPane()
                .environment(model)
                .huiverTheme()
                .frame(minWidth: 560, minHeight: 480)
        }
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

            Button("Back \(Int(SkipIntervals.backward)) Seconds") { narrator?.skip(by: -SkipIntervals.backward) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!playing)
            Button("Forward \(Int(SkipIntervals.forward)) Seconds") { narrator?.skip(by: SkipIntervals.forward) }
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
