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

    private static let panelSize = NSSize(width: 406, height: 142)

    private func makePanel(appState: AppState) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // The glass card draws its own layered soft shadows; the window's hard
        // shadow is what makes the edges look die-cut.
        panel.hasShadow = false
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
                x: visible.maxX - Self.panelSize.width - 20,
                y: visible.maxY - Self.panelSize.height - 20
            ))
        }
        // The autosaved frame may carry an older size.
        panel.setContentSize(Self.panelSize)
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
                if appState.isAppleMusicNow {
                    VStack(spacing: 6) {
                        miniButton(
                            symbol: appState.currentFavorite == true ? "star.fill" : "star",
                            label: "Favorite on Apple Music",
                            size: 13
                        ) { appState.toggleFavorite() }
                        miniButton(
                            symbol: "arrow.up.forward.app",
                            label: "Open in Apple Music",
                            size: 12
                        ) { appState.openInAppleMusic() }
                    }
                }
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
                    VStack(spacing: 6) {
                        miniButton(symbol: "arrow.up.forward.app", label: "Find in Apple Music",
                                   size: 11) { appState.findCurrentInAppleMusic() }
                        miniButton(symbol: "globe", label: "Open on pandora.com",
                                   size: 11) { appState.openPandoraSongPage() }
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 354, height: 90)
        .glassEffect(.clear.interactive(), in: Self.glassShape)
        .overlay(rimLight)
        .overlay(sheen)
        // Layered shadows: soft ambient + tight contact — reads as a slab
        // floating above the desktop. Kept light, and the margin below must
        // fully contain them or the window edge clips them into a square.
        .shadow(color: .black.opacity(0.16), radius: 11, y: 6)
        .shadow(color: .black.opacity(0.09), radius: 3, y: 1)
        .padding(26)
        .opacity(appearsActive ? 1 : 0.85)
    }

    private static var glassShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
    }

    /// Specular rim: bright refraction along the top-left edge fading to a
    /// faint dark line at the bottom — the "thickness" of the glass.
    private var rimLight: some View {
        Self.glassShape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0.10), location: 0.35),
                        .init(color: .clear, location: 0.7),
                        .init(color: .black.opacity(0.18), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.2
            )
            .allowsHitTesting(false)
    }

    /// Soft light catch across the upper face of the slab.
    private var sheen: some View {
        Self.glassShape
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.10), location: 0),
                        .init(color: .white.opacity(0.02), location: 0.45),
                        .init(color: .clear, location: 0.6),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
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
