import SwiftUI

/// The window: a sidebar of destinations, the chosen one filling the rest,
/// and the audition bar pinned under whichever detail is showing.
struct ContentView: View {
    enum Destination: String, CaseIterable, Identifiable {
        case library, player, voices, queue, sync, settings
        var id: String { rawValue }

        var label: String {
            switch self {
            case .library: "Library"
            case .player: "Now Playing"
            case .voices: "Voices"
            case .queue: "Queue"
            case .sync: "Sync"
            case .settings: "Settings"
            }
        }

        var icon: String {
            switch self {
            case .library: "books.vertical"
            case .player: "play.circle"
            case .voices: "waveform"
            case .queue: "tray.full"
            case .sync: "iphone"
            case .settings: "gearshape"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @State private var selection: Destination? = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Destination.allCases) { destination in
                    Label(destination.label, systemImage: destination.icon)
                        .tag(destination)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Everywhere except the full player, which it would repeat.
                    if model.narrator?.chapterId != nil, selection != .player {
                        MiniPlayerBar { selection = .player }
                            .background(.bar)
                            .overlay(alignment: .top) { Divider().overlay(theme.colors.border) }
                    }
                }
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { model.loadFailure != nil },
                set: { if !$0 { model.clearFailure() } }
            )
        ) {
            Button("OK") { model.clearFailure() }
        } message: {
            Text(model.loadFailure ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .library {
        case .library: LibraryView()
        case .player: PlayerView()
        case .voices: VoicesView()
        case .queue: QueueView()
        case .sync: SyncView()
        case .settings: SettingsPane()
        }
    }
}
