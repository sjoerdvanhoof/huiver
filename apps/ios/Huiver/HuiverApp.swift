import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()
    @Environment(\.colorScheme) private var scheme

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .huiverTheme(scheme)
                .task { await model.load() }
        }
    }
}
