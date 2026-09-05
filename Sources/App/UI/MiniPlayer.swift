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

/// A small AppKit-backed drag target. SwiftUI's interactive glass surface
/// consumes mouse events, so `isMovableByWindowBackground` alone is not enough
/// to make the visible card draggable.
private struct WindowDragHandle: NSViewRepresentable {
    let onActivityChanged: (Bool) -> Void

    final class DragView: NSView {
        var onActivityChanged: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            if let trackingArea { removeTrackingArea(trackingArea) }
            let trackingArea = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            onActivityChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onActivityChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
            onActivityChanged?(true)
            NSCursor.closedHand.push()
            window?.performDrag(with: event)
            NSCursor.pop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                self?.onActivityChanged?(false)
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onActivityChanged = onActivityChanged
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.onActivityChanged = onActivityChanged
    }
}

@MainActor
final class MiniPlayerController {
    private var panel: FloatingPanel?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.keepPanelOnScreen(panel)
            }
        }
    }

    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setVisible(_ visible: Bool, appState: AppState) {
        if visible {
            if panel == nil { panel = makePanel(appState: appState) }
            if let panel {
                keepPanelOnScreen(panel)
                panel.orderFrontRegardless()
            }
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
            guard delta != 0 else { return }
            appState?.adjustVolume(by: delta > 0 ? 2 : -2)
        }

        let host = NSHostingView(rootView: MiniPlayerView().environment(appState))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        panel.setFrameAutosaveName("MiniPlayer")
        let restored = panel.setFrameUsingName("MiniPlayer")
        // The autosaved frame may carry an older size.
        panel.setContentSize(Self.panelSize)
        keepPanelOnScreen(panel, restoredSavedFrame: restored)
        return panel
    }

    /// A saved position can point at a disconnected display, or leave the drag
    /// handle out of reach after a display resolution or arrangement change.
    private func keepPanelOnScreen(_ panel: NSPanel, restoredSavedFrame: Bool = true) {
        guard let fallback = NSScreen.main ?? NSScreen.screens.first else { return }
        let matchingScreen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.visibleFrame.intersection(panel.frame)
            let right = rhs.visibleFrame.intersection(panel.frame)
            return max(0, left.width) * max(0, left.height)
                < max(0, right.width) * max(0, right.height)
        }
        let screen = matchingScreen.flatMap {
            $0.visibleFrame.intersects(panel.frame) ? $0 : nil
        }
        let visible = (screen ?? fallback).visibleFrame
        let origin: NSPoint
        if !restoredSavedFrame || screen == nil {
            origin = NSPoint(x: visible.maxX - panel.frame.width - 20,
                             y: visible.maxY - panel.frame.height - 20)
        } else {
            origin = panel.frame.origin
        }
        panel.setFrameOrigin(NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panel.frame.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
        ))
    }
}

struct MiniPlayerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appearsActive) private var appearsActive
    @State private var dragHandleActive = false

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
        .overlay(alignment: .top) {
            ZStack {
                WindowDragHandle { active in
                    dragHandleActive = active
                }
                Capsule()
                    .fill(.white.opacity(0.38))
                    .frame(width: 34, height: 3)
                    .opacity(dragHandleActive ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .frame(width: 72, height: 16)
            .contentShape(Rectangle())
            .accessibilityLabel("Move mini player")
            .animation(.easeOut(duration: 0.22), value: dragHandleActive)
        }
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
        .help(enabled ? label : "Thumbs need a playing Pandora track")
        .accessibilityLabel(label)
    }
}
