import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @State private var sync = SyncModel()
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var phase

    init() {
        // Has to happen before launch finishes, which rules out doing it when
        // the converter is created.
        Converter.registerBackgroundTask()
        SyncModel.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .environment(sync)
                .huiverTheme()
                // Model loading keeps running underneath: onboarding and the
                // first compile are concurrent, so the waterline is already
                // mid-fill when the cover comes down.
                .fullScreenCover(isPresented: .init(
                    get: { !onboarded },
                    set: { if !$0 { onboarded = true } }
                )) {
                    OnboardingView { onboarded = true }
                        .environment(model)
                        .huiverTheme()
                        .interactiveDismissDisabled()
                }
                .task { await model.load() }
                .onChange(of: phase) { _, new in
                    switch new {
                    case .background:
                        model.converter?.applicationDidEnterBackground()
                        // Browsing for a Mac the app cannot reach costs battery
                        // for nothing; the slot asked for here is what carries
                        // on later.
                        sync.stopWatching()
                        sync.scheduleBackgroundSync()
                        // The ticker stops when the app is suspended, and being
                        // killed while suspended is the usual way this app ends.
                        // Write the position down while there is still a process
                        // to write it from.
                        model.narrator?.checkpoint()
                    case .active:
                        model.converter?.applicationWillEnterForeground()
                        sync.startWatching(model: model)
                        // Core ML stops working while the screen is locked, so a
                        // chapter being read aloud loses its renderer within
                        // seconds of the phone going in a pocket. Coming back is
                        // when it can be picked up again.
                        model.narrator?.resumeRendering()
                    default: break
                    }
                }
        }
    }
}
