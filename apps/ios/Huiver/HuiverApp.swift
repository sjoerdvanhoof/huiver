import SwiftUI

@main
struct HuiverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .task { await model.load() }
        }
    }
}
