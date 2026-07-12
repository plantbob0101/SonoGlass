import SwiftUI
import AppKit
import SonosKit

/// Borderless, non-activating, always-on-top panel. Clicking its controls
/// must never steal focus from the frontmost app.
final class FloatingPanel: NSPanel {
    var onScroll: ((CGFloat) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}

@MainActor
final class MiniPlayerController {
    private var panel: FloatingPanel?

    func setVisible(_ visible: Bool, appState: AppState) {
        if visible {
            if panel == nil { panel = makePanel(appState: appState) }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel(appState: AppState) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.onScroll = { [weak appState] delta in
            appState?.adjustVolume(by: delta > 0 ? 2 : -2)
        }

        let host = NSHostingView(rootView: MiniPlayerView().environment(appState))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        panel.setFrameAutosaveName("MiniPlayer")
        if !panel.setFrameUsingName("MiniPlayer"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - 350,
                y: visible.maxY - 112
            ))
        }
        return panel
    }
}

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: appState.nowPlaying.artURL, size: 68, cornerRadius: 10)
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) {
                        appState.copyDebugURIs()
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.nowPlaying.title.isEmpty ? "Nothing playing" : appState.nowPlaying.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(appState.nowPlaying.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(appState.selectedGroup?.displayName ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if appState.isPandoraNow {
                    VStack(spacing: 6) {
                        miniButton(
                            symbol: appState.currentThumb == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                            label: "Thumbs up",
                            enabled: appState.thumbsAvailable
                        ) { appState.thumbsUp() }
                        miniButton(
                            symbol: appState.currentThumb == false ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            label: "Thumbs down",
                            enabled: appState.thumbsAvailable
                        ) { appState.thumbsDown() }
                    }
                }
                miniButton(
                    symbol: appState.nowPlaying.transport.isPlaying ? "pause.fill" : "play.fill",
                    label: appState.nowPlaying.transport.isPlaying ? "Pause" : "Play",
                    size: 16
                ) { appState.togglePlayPause() }
                miniButton(symbol: "forward.fill", label: "Skip") { appState.next() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 330, height: 92)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(appearsActive ? 1 : 0.85)
    }

    private func miniButton(symbol: String, label: String, size: CGFloat = 12,
                            enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? label : "Link Pandora for thumbs in Settings")
        .accessibilityLabel(label)
    }
}
