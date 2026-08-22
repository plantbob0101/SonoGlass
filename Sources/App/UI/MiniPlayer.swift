import SwiftUI
import AppKit
import SonosKit

/// Borderless, always-on-top panel with explicit drag handling outside its
/// controls.
final class FloatingPanel: NSPanel {
    var onScroll: ((CGFloat) -> Void)?
    private var dragEventMonitor: Any?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    func installDragHandling() {
        guard dragEventMonitor == nil else { return }
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            switch event.type {
            case .leftMouseDown:
                let location = event.locationInWindow
                let topHandle = NSRect(x: 0, y: self.frame.height - 26,
                                       width: self.frame.width, height: 26)
                let titleHandle = NSRect(x: 105, y: 32, width: 145, height: 78)
                guard topHandle.contains(location) || titleHandle.contains(location) else {
                    return event
                }
                self.dragStartMouseLocation = NSEvent.mouseLocation
                self.dragStartWindowOrigin = self.frame.origin
                return nil
            case .leftMouseDragged:
                guard let startMouse = self.dragStartMouseLocation,
                      let startOrigin = self.dragStartWindowOrigin else { return event }
                let currentMouse = NSEvent.mouseLocation
                self.setFrameOrigin(NSPoint(
                    x: startOrigin.x + currentMouse.x - startMouse.x,
                    y: startOrigin.y + currentMouse.y - startMouse.y
                ))
                return nil
            case .leftMouseUp:
                guard self.dragStartMouseLocation != nil else { return event }
                self.dragStartMouseLocation = nil
                self.dragStartWindowOrigin = nil
                UserDefaults.standard.set(
                    NSStringFromRect(self.frame),
                    forKey: "MiniPlayerFrame"
                )
                return nil
            default:
                return event
            }
        }
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
            styleMask: [.borderless],
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
        panel.installDragHandling()

        let host = NSHostingView(rootView: MiniPlayerView().environment(appState))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        let restoredSavedFrame = restoreSavedFrame(panel)
        // The autosaved frame may carry an older size.
        panel.setContentSize(Self.panelSize)
        keepPanelOnScreen(panel, restoredSavedFrame: restoredSavedFrame)
        return panel
    }

    private func restoreSavedFrame(_ panel: NSPanel) -> Bool {
        guard let value = UserDefaults.standard.string(forKey: "MiniPlayerFrame") else {
            return false
        }
        let frame = NSRectFromString(value)
        guard frame.width > 0, frame.height > 0 else { return false }
        panel.setFrame(frame, display: false)
        return true
    }

    /// Saved coordinates can point outside the active desktop after changing
    /// monitors or display modes. Keep the complete player reachable.
    private func keepPanelOnScreen(_ panel: NSPanel, restoredSavedFrame: Bool) {
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return }

        let matchingScreen = NSScreen.screens.first {
            $0.visibleFrame.intersects(panel.frame)
        }
        guard restoredSavedFrame, let screen = matchingScreen else {
            let visible = fallbackScreen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.panelSize.width - 20,
                y: visible.maxY - Self.panelSize.height - 20
            ))
            return
        }

        let visible = screen.visibleFrame
        let maxX = max(visible.minX, visible.maxX - panel.frame.width)
        let maxY = max(visible.minY, visible.maxY - panel.frame.height)
        panel.setFrameOrigin(NSPoint(
            x: min(max(panel.frame.minX, visible.minX), maxX),
            y: min(max(panel.frame.minY, visible.minY), maxY)
        ))
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
                MarqueeText(
                    text: appState.nowPlaying.title.isEmpty ? "Nothing playing" : appState.nowPlaying.title,
                    font: .system(size: 12, weight: .semibold)
                )
                MarqueeText(text: appState.nowPlaying.artist, font: .system(size: 11))
                    .foregroundStyle(.secondary)
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
