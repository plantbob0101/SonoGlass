import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif
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
    /// Apple Music favorite state per catalog song id.
    var favoriteCache: [String: Bool] = [:]

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
    let appleMusic = AppleMusicRatings()

    #if os(macOS)
    @ObservationIgnored private var miniPlayer: MiniPlayerController?
    #endif
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

    // MARK: - Apple Music detection

    var appleMusicSid: Int? {
        services.first { $0.name == "Apple Music" }?.id
    }

    var currentAppleMusicSongID: String? {
        guard let songID = AppleMusicURI.songID(fromTrackURI: nowPlaying.trackURI) else { return nil }
        // Confirm the track really belongs to the Apple Music service.
        if let sidParam = SonosURI.queryParam("sid", in: nowPlaying.trackURI),
           let sid = Int(sidParam), let amSid = appleMusicSid {
            return sid == amSid ? songID : nil
        }
        return songID
    }

    var isAppleMusicNow: Bool { currentAppleMusicSongID != nil }

    /// Favorite state of the current Apple Music song (nil = unknown/unrated).
    var currentFavorite: Bool? {
        guard let songID = currentAppleMusicSongID else { return nil }
        return favoriteCache[songID]
    }

    func toggleFavorite() {
        guard let songID = currentAppleMusicSongID else { return }
        let target = !(favoriteCache[songID] ?? false)
        favoriteCache[songID] = target
        Task {
            do {
                try await appleMusic.setFavorite(songID: songID, favorite: target)
            } catch {
                favoriteCache[songID] = nil
                showToast("\(error)")
            }
        }
    }

    /// Opens the current Apple Music song in the Music app, highlighted on its
    /// album page (same deep link Shazam uses).
    func openInAppleMusic() {
        guard let songID = currentAppleMusicSongID,
              let url = URL(string: "music://music.apple.com/us/song/\(songID)") else { return }
        platformOpen(url)
    }

    /// For a Pandora track: search Apple Music for the same song and open the
    /// top match in the Music app — the library-building funnel.
    func findCurrentInAppleMusic() {
        let title = nowPlaying.title
        let artist = nowPlaying.artist
        guard !title.isEmpty else { return }
        Task {
            do {
                if let id = try await appleMusic.findSong(title: title, artist: artist),
                   let url = URL(string: "music://music.apple.com/us/song/\(id)") {
                    platformOpen(url)
                } else {
                    showToast("No Apple Music match for “\(title)”")
                }
            } catch {
                showToast("\(error)")
            }
        }
    }

    /// Opens the current Pandora track's backstage page on pandora.com
    /// (collect it, browse similar artists…). Falls back to a search page.
    func openPandoraSongPage() {
        let title = nowPlaying.title
        let artist = nowPlaying.artist
        let ref = currentTrackRef
        Task {
            if pandoraConfigured, case let .modern(trackId, _)? = ref,
               let url = try? await pandora.trackPageURL(pandoraId: trackId) {
                platformOpen(url)
                return
            }
            let query = "\(title) \(artist)"
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            if let url = URL(string: "https://www.pandora.com/search/\(query)/tracks") {
                platformOpen(url)
            }
        }
    }

    /// Fetch the server-side favorite state when an Apple Music track appears.
    private func refreshFavoriteState() {
        guard let songID = currentAppleMusicSongID, favoriteCache[songID] == nil else { return }
        Task {
            if let loved = try? await appleMusic.isFavorite(songID: songID) {
                if favoriteCache[songID] == nil { favoriteCache[songID] = loved }
            }
        }
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
        #if os(macOS)
        if defaults.bool(forKey: "showMiniAtLaunch") {
            miniPlayerVisible = true
            // Defer panel creation until the app has finished launching.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.updateMiniPlayer()
            }
        }
        #endif
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
                refreshFavoriteState()
            case .volume(let v, let m):
                if volumeSendTask == nil { volume = Double(v) }
                muted = m
            case .memberVolumes(let vols):
                for (udn, v) in vols where memberVolumeTasks[udn] == nil {
                    memberVolumes[udn] = v
                }
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

    // MARK: - Group editing

    /// Every visible room in the household, one entry per player.
    var allRooms: [SonosDevice] {
        var seen = Set<String>()
        return groups.flatMap(\.members)
            .filter { seen.insert($0.udn).inserted }
            .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
    }

    var selectedGroupMemberUDNs: Set<String> {
        Set(selectedGroup?.members.map(\.udn) ?? [])
    }

    func setRoom(_ device: SonosDevice, grouped: Bool) {
        Task {
            do {
                if grouped {
                    try await system.joinCurrentGroup(device: device)
                } else {
                    try await system.removeFromGroup(device: device)
                }
            } catch {
                showToast("\(error)")
            }
        }
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

    // MARK: - Per-room volume within a group

    var memberVolumes: [String: Int] = [:]
    @ObservationIgnored private var memberVolumeTasks: [String: Task<Void, Never>] = [:]

    func memberVolumeChanged(_ device: SonosDevice, to value: Double) {
        memberVolumes[device.udn] = Int(value)
        memberVolumeTasks[device.udn]?.cancel()
        memberVolumeTasks[device.udn] = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            try? await system.setMemberVolume(Int(value), device: device)
            memberVolumeTasks[device.udn] = nil
        }
    }

    func memberVolumeCommitted(_ device: SonosDevice) {
        memberVolumeTasks[device.udn]?.cancel()
        memberVolumeTasks[device.udn] = nil
        guard let value = memberVolumes[device.udn] else { return }
        Task { try? await system.setMemberVolume(value, device: device) }
    }

    func toggleMute() {
        let target = !muted
        muted = target
        Task {
            do { try await system.setMute(target) } catch { showToast("\(error)") }
        }
    }

    // MARK: - Pandora thumbs (player rates through its own service session)

    func thumbsUp() { rate(positive: true) }
    func thumbsDown() { rate(positive: false) }

    private func rate(positive: Bool) {
        guard thumbsAvailable else { return }
        let key = thumbKey
        let trackBefore = nowPlaying.trackURI
        thumbCache[key] = positive
        Task {
            do {
                try await system.rateCurrentTrack(thumbsUp: positive)
                if !positive {
                    // Pandora convention: thumbs-down skips. The service usually
                    // auto-skips; only skip manually if the track didn't change.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await system.pollOnce()
                    if nowPlaying.trackURI == trackBefore {
                        try? await system.next()
                    }
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

    #if os(macOS)
    func toggleMiniPlayer() {
        miniPlayerVisible.toggle()
        updateMiniPlayer()
    }

    func updateMiniPlayer() {
        if miniPlayer == nil { miniPlayer = MiniPlayerController() }
        miniPlayer?.setVisible(miniPlayerVisible, appState: self)
    }
    #endif

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
        platformSetClipboard(text)
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
        platformSetClipboard(lines.joined(separator: "\n"))
        showToast("Diagnostics copied")
    }
}

// MARK: - Platform shims

@MainActor
func platformOpen(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

@MainActor
func platformSetClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
