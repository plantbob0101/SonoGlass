import SwiftUI
import SonosKit

@main
struct SonoGlassApp: App {
    @State private var appState = AppState()
    @AppStorage("showTitleInMenuBar") private var showTitleInMenuBar = false

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appState)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        let playing = appState.nowPlaying.transport.isPlaying
        let multi = (appState.selectedGroup?.members.count ?? 1) > 1
        let symbol = multi ? "hifispeaker.2" : "hifispeaker"
        if showTitleInMenuBar, playing, !appState.nowPlaying.title.isEmpty {
            Label {
                Text(truncatedTitle)
            } icon: {
                Image(systemName: symbol + ".fill")
            }
        } else {
            Image(systemName: playing ? symbol + ".fill" : symbol)
        }
    }

    private var truncatedTitle: String {
        let title = appState.nowPlaying.title
        return title.count > 30 ? String(title.prefix(29)) + "…" : title
    }
}
