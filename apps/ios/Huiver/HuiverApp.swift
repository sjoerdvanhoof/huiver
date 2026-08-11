import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase

    init() {
        // Has to happen before launch finishes, which rules out doing it when
        // the converter is created.
        Converter.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .huiverTheme(scheme)
                .task { await model.load() }
                .onChange(of: phase) { _, new in
                    switch new {
                    case .background: model.converter?.applicationDidEnterBackground()
                    case .active: model.converter?.applicationWillEnterForeground()
                    default: break
                    }
                }
        }
    }
}
