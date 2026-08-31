import SwiftUI

/// Which pane the window is showing, held where every screen can reach it.
///
/// The sidebar owns a selection either way; making it observable is what lets
/// a chapter row open the player when playback starts — the alternative is
/// threading a closure through every list that can play something.
@MainActor
@Observable
final class AppNavigation {
    var selection: ContentView.Destination? = .library

    func showPlayer() { selection = .player }
}

/// The window: a sidebar of destinations, the chosen one filling the rest,
/// and the audition bar pinned under whichever detail is showing.
struct ContentView: View {
    enum Destination: String, CaseIterable, Identifiable {
        case library, player, voices, queue, sync, settings
        // Compiled out of Release with its view: listeners never see the lab.
        #if DEBUG
        case devLab
        #endif
        var id: String { rawValue }

        var label: String {
            switch self {
            case .library: "Library"
            case .player: "Now Playing"
            case .voices: "Voices"
            case .queue: "Queue"
            case .sync: "Sync"
            case .settings: "Settings"
            #if DEBUG
            case .devLab: "Pronunciation Lab"
            #endif
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
            #if DEBUG
            case .devLab: "testtube.2"
            #endif
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    @AppStorage("onboarded") private var onboarded = false
    @State private var navigation = AppNavigation()

    var body: some View {
        @Bindable var navigation = navigation

        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(Destination.allCases) { destination in
                    Label(destination.label, systemImage: destination.icon)
                        .tag(destination)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        PreparingWaterline(
                            progress: model.preparing,
                            since: model.preparingSince,
                            firstRun: !model.hasPreparedBefore
                        )
                        // Everywhere except the full player, which it would repeat.
                        if model.narrator?.chapterId != nil, navigation.selection != .player {
                            MiniPlayerBar { navigation.showPlayer() }
                                .background(.bar)
                                .overlay(alignment: .top) { Divider().overlay(theme.colors.border) }
                        }
                    }
                }
        }
        .environment(navigation)
        .sheet(isPresented: .init(
            get: { !onboarded },
            set: { if !$0 { onboarded = true } }
        )) {
            OnboardingSheet { onboarded = true }
                .environment(model)
                .huiverTheme()
        }
        // A book arrived in a language nobody has picked a voice for. One
        // sheet per language; dismissing moves on to the next in the queue.
        .sheet(item: .init(
            get: { onboarded ? model.pendingLanguagePrompts.first : nil },
            set: { if $0 == nil, !model.pendingLanguagePrompts.isEmpty {
                model.pendingLanguagePrompts.removeFirst()
            } }
        )) { prompt in
            NewLanguageSheet(prompt: prompt)
                .environment(model)
                .huiverTheme()
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
        // Imports get their own alert: a bad EPUB is not the engine's fault,
        // and used to be reported as if it were.
        .alert(
            "Could not import",
            isPresented: .init(
                get: { model.importFailure != nil },
                set: { if !$0 { model.importFailure = nil } }
            )
        ) {
            Button("OK") { model.importFailure = nil }
        } message: {
            Text(model.importFailure ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .library {
        case .library: LibraryView()
        case .player: PlayerView()
        case .voices: VoicesView()
        case .queue: QueueView()
        case .sync: SyncView()
        case .settings: SettingsPane()
        #if DEBUG
        case .devLab: DevLabView()
        #endif
        }
    }
}
