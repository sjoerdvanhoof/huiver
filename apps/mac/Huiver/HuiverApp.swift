import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @State private var sync = MacSyncModel()
    @Environment(\.colorScheme) private var scheme

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(sync)
                .huiverTheme(scheme)
                .task {
                    await model.load()
                    // After the library exists: an inbound sync session reads
                    // straight out of it.
                    sync.startAdvertising(model: model)
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
