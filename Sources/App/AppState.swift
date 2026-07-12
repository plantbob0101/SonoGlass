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

    // Pandora SMAPI (thumbs on modern cloud-queue firmware)
    var smapiLinked = false
    @ObservationIgnored var smapiCredentials: SMAPICredentials?
    var linkInProgress = false
    var linkPrompt: SMAPIDeviceLink?

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

    /// A rateable Pandora track is playing (SMAPI needs only the item id from
    /// the track URI, which every x-sonos-http Pandora track carries).
    var thumbsAvailable: Bool {
        isPandoraNow && !nowPlaying.trackURI.isEmpty
    }

    /// Stable per-track key for the optimistic thumb cache.
    private var thumbKey: String { nowPlaying.trackURI }

    var currentThumb: Bool? {
        guard thumbsAvailable else { return nil }
        // Optimistic local state wins; fall back to the speaker-reported rating.
        return thumbCache[thumbKey] ?? nowPlaying.rating
    }

    // MARK: - Lifecycle

    init() {
        if let creds = PandoraKeychain.load() {
            pandoraConfigured = true
            Task { await pandora.setCredentials(username: creds.username, password: creds.password) }
        }
        if let data = PandoraSMAPIKeychain.load(),
           let creds = try? JSONDecoder().decode(SMAPICredentials.self, from: data) {
            smapiCredentials = creds
            smapiLinked = true
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

    // MARK: - Pandora thumbs (via Sonos SMAPI rateItem)

    func thumbsUp() { rate(positive: true) }
    func thumbsDown() { rate(positive: false) }

    private func rate(positive: Bool) {
        guard thumbsAvailable else { return }
        guard smapiLinked, let creds = smapiCredentials else {
            showToast("Link Pandora for thumbs in Settings")
            return
        }
        let key = thumbKey
        thumbCache[key] = positive
        Task {
            do {
                let shouldSkip = try await system.smapiRateCurrent(
                    rating: positive ? .thumbsUp : .thumbsDown, credentials: creds)
                // Thumbs-down auto-skips on Pandora; honor the service's hint,
                // and skip anyway by convention if it didn't ask.
                if !positive, !shouldSkip {
                    try? await system.next()
                }
            } catch {
                thumbCache[key] = nil
                showToast("\(error)")
            }
        }
    }

    // MARK: - Pandora SMAPI device link

    /// Starts the AppLink flow; returns the URL the user must open to authorize.
    func beginPandoraLink() async -> String {
        linkInProgress = true
        do {
            let link = try await system.smapiBeginLink()
            linkPrompt = link
            // Poll for authorization for up to ~5 minutes.
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                do {
                    let creds = try await system.smapiPollToken(link: link)
                    if let data = try? JSONEncoder().encode(creds) {
                        try? PandoraSMAPIKeychain.save(data)
                    }
                    smapiCredentials = creds
                    smapiLinked = true
                    linkInProgress = false
                    linkPrompt = nil
                    return "linked"
                } catch let error as SMAPIError {
                    switch error {
                    case .notLinkedRetry, .transport:
                        continue   // keep polling through network blips
                    default:
                        linkInProgress = false
                        linkPrompt = nil
                        return "\(error)"
                    }
                }
            }
            linkInProgress = false
            linkPrompt = nil
            return "Timed out waiting for authorization"
        } catch {
            linkInProgress = false
            linkPrompt = nil
            return "\(error)"
        }
    }

    func unlinkPandoraThumbs() {
        PandoraSMAPIKeychain.delete()
        smapiCredentials = nil
        smapiLinked = false
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
