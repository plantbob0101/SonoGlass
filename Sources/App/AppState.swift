import SwiftUI
import Observation
import SonosKit
import PandoraKit

enum PopoverTab: String, CaseIterable {
    case nowPlaying = "Now Playing"
    case favorites = "Favorites"
    case stations = "Stations"
}

@MainActor
@Observable
final class AppState {
    // Sonos state
    var groups: [ZoneGroup] = []
    var selectedGroupID: String?
    var nowPlaying = NowPlayingState()
    var volume: Double = 0
    var muted = false
    var discovery: DiscoveryPhase = .idle
    var eventsHealthy = false
    var reachable = true
    var services: [MusicService] = []
    var pandoraSid = 236

    // Pandora state
    var pandoraConfigured = false
    var stations: [PandoraStation] = []
    /// Optimistic per-trackToken feedback cache (cleared when the track changes).
    var thumbCache: [String: Bool] = [:]

    // Browse state
    var favorites: [DIDLItem] = []
    var playlists: [DIDLItem] = []

    // UI state
    var tab: PopoverTab = .nowPlaying
    var toast: String?
    var miniPlayerVisible = false

    let system = SonosSystem()
    let pandora = PandoraClient()

    @ObservationIgnored private var miniPlayer: MiniPlayerController?
    @ObservationIgnored private var volumeSendTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    var selectedGroup: ZoneGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    var coordinatorIP: String? { selectedGroup?.coordinator?.ip }

    // MARK: - Pandora detection

    var currentTrackRef: PandoraTrackRef? {
        PandoraTrackRef.parse(trackURI: nowPlaying.trackURI)
    }

    var isPandoraNow: Bool {
        guard nowPlaying.stationURI.lowercased().hasPrefix("x-sonosapi-radio:") else { return false }
        guard let sid = SonosURI.queryParam("sid", in: nowPlaying.stationURI) else { return false }
        return sid == String(pandoraSid)
    }

    var thumbsAvailable: Bool { isPandoraNow && currentTrackRef != nil }

    var currentThumb: Bool? {
        guard let ref = currentTrackRef else { return nil }
        // Optimistic local state wins; fall back to the speaker-reported rating.
        return thumbCache[ref.cacheKey] ?? nowPlaying.rating
    }

    private var elapsedSeconds: Int {
        let parts = nowPlaying.relTime.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: - Lifecycle

    init() {
        if let creds = PandoraKeychain.load() {
            pandoraConfigured = true
            Task { await pandora.setCredentials(username: creds.username, password: creds.password) }
        }
        Task { await consumeUpdates() }
        let defaults = UserDefaults.standard
        let manualIP = defaults.string(forKey: "manualIP")
        let defaultRoom = defaults.string(forKey: "defaultRoom")
        Task { await system.start(manualIP: manualIP, preferredRoom: defaultRoom) }
        if defaults.bool(forKey: "showMiniAtLaunch") {
            miniPlayerVisible = true
            // Defer panel creation until the app has finished launching.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.updateMiniPlayer()
            }
        }
    }

    private func consumeUpdates() async {
        for await update in system.updates {
            switch update {
            case .discovery(let phase):
                discovery = phase
            case .groups(let newGroups, let selectedID):
                groups = newGroups
                selectedGroupID = selectedID
            case .nowPlaying(let np):
                nowPlaying = np
            case .volume(let v, let m):
                if volumeSendTask == nil { volume = Double(v) }
                muted = m
            case .services(let list):
                services = list
                Task { pandoraSid = await system.currentPandoraServiceID() }
            case .eventsHealthy(let healthy):
                eventsHealthy = healthy
            case .reachable(let ok):
                reachable = ok
                if !ok { showToast("Reconnecting to Sonos…") }
            case .toast(let message):
                showToast(message)
            }
        }
    }

    func retryDiscovery() {
        let manualIP = UserDefaults.standard.string(forKey: "manualIP")
        Task { await system.refresh(manualIP: manualIP) }
    }

    func popoverOpened() {
        Task { await system.pollOnce() }
        refreshBrowseLists()
    }

    func refreshBrowseLists() {
        Task {
            if let favs = try? await system.browseFavorites() { favorites = favs }
            if let lists = try? await system.browsePlaylists() { playlists = lists }
        }
        if pandoraConfigured {
            Task {
                if let list = try? await pandora.stationList() { stations = list }
            }
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        Task {
            do {
                if nowPlaying.transport.isPlaying {
                    try await system.pause()
                } else {
                    try await system.play()
                }
            } catch {
                showToast("\(error)")
            }
        }
    }

    func next() {
        Task {
            do {
                try await system.next()
            } catch {
                if isPandoraNow {
                    showToast("Pandora skip limit reached")
                } else {
                    showToast("\(error)")
                }
            }
        }
    }

    func previous() {
        Task {
            do { try await system.previous() } catch { showToast("\(error)") }
        }
    }

    func selectGroup(_ id: String) {
        selectedGroupID = id
        Task { await system.selectGroup(id: id) }
    }

    // MARK: - Volume

    /// Debounced live slider updates (≤10 calls/s).
    func volumeChanged(_ value: Double) {
        volume = value
        volumeSendTask?.cancel()
        volumeSendTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            try? await system.setVolume(Int(value))
            volumeSendTask = nil
        }
    }

    /// Final value on slider release.
    func volumeCommitted() {
        volumeSendTask?.cancel()
        volumeSendTask = nil
        let value = Int(volume)
        Task { try? await system.setVolume(value) }
    }

    func adjustVolume(by delta: Double) {
        let newValue = min(100, max(0, volume + delta))
        volumeChanged(newValue)
    }

    func toggleMute() {
        let target = !muted
        muted = target
        Task {
            do { try await system.setMute(target) } catch { showToast("\(error)") }
        }
    }

    // MARK: - Pandora thumbs

    func thumbsUp() {
        guard let ref = currentTrackRef, pandoraConfigured else { return }
        thumbCache[ref.cacheKey] = true
        let elapsed = elapsedSeconds
        Task {
            do {
                try await pandora.addFeedback(ref: ref, isPositive: true, elapsedSeconds: elapsed)
            } catch {
                thumbCache[ref.cacheKey] = nil
                showToast("\(error)")
            }
        }
    }

    func thumbsDown() {
        guard let ref = currentTrackRef, pandoraConfigured else { return }
        thumbCache[ref.cacheKey] = false
        let elapsed = elapsedSeconds
        Task {
            do {
                try await pandora.addFeedback(ref: ref, isPositive: false, elapsedSeconds: elapsed)
                // Pandora convention: a thumbs-down skips the track.
                try await system.next()
            } catch {
                thumbCache[ref.cacheKey] = nil
                showToast("\(error)")
            }
        }
    }

    // MARK: - Browse playback

    func play(favorite: DIDLItem) {
        tab = .nowPlaying
        Task {
            do { try await system.playFavorite(favorite) } catch { showToast("\(error)") }
        }
    }

    func play(station: PandoraStation) {
        tab = .nowPlaying
        Task {
            do {
                try await system.playPandoraStation(stationID: station.stationId,
                                                    name: station.stationName)
            } catch {
                showToast("\(error)")
            }
        }
    }

    // MARK: - Pandora account

    func savePandoraCredentials(username: String, password: String) async -> String {
        do {
            try PandoraKeychain.save(.init(username: username, password: password))
        } catch {
            return "Keychain error: \(error.localizedDescription)"
        }
        await pandora.setCredentials(username: username, password: password)
        pandoraConfigured = true
        do {
            try await pandora.verify()
            refreshBrowseLists()
            return "Connected to Pandora ✓"
        } catch {
            return "\(error)"
        }
    }

    func removePandoraAccount() {
        PandoraKeychain.delete()
        pandoraConfigured = false
        stations = []
        if tab == .stations { tab = .nowPlaying }
        Task { await pandora.clearCredentials() }
    }

    // MARK: - Mini player

    func toggleMiniPlayer() {
        miniPlayerVisible.toggle()
        updateMiniPlayer()
    }

    func updateMiniPlayer() {
        if miniPlayer == nil { miniPlayer = MiniPlayerController() }
        miniPlayer?.setVisible(miniPlayerVisible, appState: self)
    }

    // MARK: - Misc

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    /// Option-click debug affordance: copies raw station + track URIs.
    func copyDebugURIs() {
        let text = "stationURI: \(nowPlaying.stationURI)\ntrackURI: \(nowPlaying.trackURI)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Raw URIs copied")
    }

    func copyDiagnostics() {
        var lines: [String] = ["SonoGlass diagnostics", ""]
        lines.append("Discovery: \(discovery)")
        lines.append("Events healthy: \(eventsHealthy)  Reachable: \(reachable)")
        lines.append("Pandora sid: \(pandoraSid)  configured: \(pandoraConfigured)")
        lines.append("")
        for group in groups {
            lines.append("Group \(group.displayName) [\(group.id)] coordinator=\(group.coordinatorUDN)")
            for member in group.members {
                lines.append("  \(member.roomName) \(member.ip) \(member.udn)")
            }
        }
        lines.append("")
        lines.append("Transport: \(nowPlaying.transport.rawValue)")
        lines.append("Track: \(nowPlaying.title) — \(nowPlaying.artist)")
        lines.append("stationURI: \(nowPlaying.stationURI)")
        lines.append("trackURI: \(nowPlaying.trackURI)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showToast("Diagnostics copied")
    }
}
