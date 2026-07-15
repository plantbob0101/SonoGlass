import SwiftUI
import SonosKit

struct PopoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            if appState.groups.isEmpty {
                emptyState
            } else {
                Picker("View", selection: $state.tab) {
                    ForEach(availableTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                switch appState.tab {
                case .nowPlaying:
                    NowPlayingSection()
                case .favorites:
                    FavoritesSection()
                case .stations:
                    StationsSection()
                }
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .overlay(alignment: .bottom) {
            if let toast = appState.toast {
                ToastView(message: toast)
                    .padding(.bottom, 46)
            }
        }
        .onAppear { appState.popoverOpened() }
    }

    private var availableTabs: [PopoverTab] {
        appState.pandoraConfigured
            ? PopoverTab.allCases
            : [.nowPlaying, .favorites]
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            switch appState.discovery {
            case .searching, .idle:
                ProgressView()
                Text("Searching for Sonos…")
                    .foregroundStyle(.secondary)
            default:
                Image(systemName: "hifispeaker.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("No speakers found")
                    .font(.headline)
                Text("Check that this Mac has Local Network access:\nSystem Settings → Privacy & Security → Local Network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { appState.retryDiscovery() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                appState.toggleMiniPlayer()
            } label: {
                Image(systemName: appState.miniPlayerVisible ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(appState.miniPlayerVisible ? "Hide mini player" : "Show floating mini player")
            .accessibilityLabel("Toggle mini player")

            if !appState.eventsHealthy && !appState.groups.isEmpty {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Live events unavailable — using fast polling")
            }
            if !appState.reachable {
                Text("Reconnecting…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button {
                // Menu bar apps aren't active when the popover clicks through,
                // so the Settings window opens behind everything unless we
                // activate and raise it ourselves.
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NSApp.activate(ignoringOtherApps: true)
                    let settings = NSApp.windows.first {
                        $0.identifier?.rawValue.contains("Settings") == true
                            || $0.title.localizedCaseInsensitiveContains("settings")
                    }
                    settings?.makeKeyAndOrderFront(nil)
                    settings?.orderFrontRegardless()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit SonoGlass")
            .accessibilityLabel("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .transition(.opacity)
    }
}
