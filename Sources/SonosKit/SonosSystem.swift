import Foundation
import os

private let systemLog = Logger(subsystem: "com.sonoglass", category: "system")

public enum DiscoveryPhase: Sendable, Equatable {
    case idle
    case searching
    case found(Int)
    case none
}

public enum SonosUpdate: Sendable {
    case discovery(DiscoveryPhase)
    case groups([ZoneGroup], selectedID: String?)
    case nowPlaying(NowPlayingState)
    case volume(Int, muted: Bool)
    case memberVolumes([String: Int])   // udn → volume, for the selected group
    case services([MusicService])
    case eventsHealthy(Bool)
    case reachable(Bool)
    case toast(String)
}

public actor SonosSystem {
    public nonisolated let updates: AsyncStream<SonosUpdate>
    private let continuation: AsyncStream<SonosUpdate>.Continuation

    private let soap = SOAPClient()

    private var groups: [ZoneGroup] = []
    private var selectedGroupID: String?
    private var nowPlaying = NowPlayingState()
    private var volume = 0
    private var muted = false
    private var services: [MusicService] = []
    private var pandoraServiceID = 236
    private var lastSeenSN = "1"

    private var eventServer: EventHTTPServer?
    private var eventPort: UInt16 = 0
    private var subscriptions: [GENA.Subscription] = []
    private var renewTasks: [Task<Void, Never>] = []
    private var sidKinds: [String: SonosUPnPService] = [:]
    private var eventsHealthy = false
    private var memberVols: [String: Int] = [:]
    private var lastGroupVolumeSetAt = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var pollFailures = 0
    private var reachable = true

    private var cachedFavorites: [DIDLItem] = []
    private let smapi = PandoraSMAPI()
    private let muse = MuseClient()

    public init() {
        (updates, continuation) = AsyncStream.makeStream(of: SonosUpdate.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Convenience

    private var selectedGroup: ZoneGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    private var coordinator: SonosDevice? { selectedGroup?.coordinator }

    private func requireCoordinator() throws -> SonosDevice {
        guard let c = coordinator else { throw SonosError(message: "No Sonos group selected") }
        return c
    }

    private func emit(_ update: SonosUpdate) {
        continuation.yield(update)
    }

    // MARK: - Lifecycle

    public func start(manualIP: String?, preferredRoom: String?) async {
        emit(.discovery(.searching))
        await discover(manualIP: manualIP, preferredRoom: preferredRoom)
    }

    public func refresh(manualIP: String?) async {
        emit(.discovery(.searching))
        await discover(manualIP: manualIP, preferredRoom: nil)
    }

    private func discover(manualIP: String?, preferredRoom: String?) async {
        async let ssdp = SSDPDiscovery.search(duration: 3.0)
        async let bonjour = BonjourDiscovery.search(duration: 3.0)
        var ips = await ssdp.union(await bonjour)
        if let manualIP, !manualIP.isEmpty {
            if let validated = SonosAddress.privateIPv4(manualIP) {
                ips.insert(validated)
            } else {
                emit(.toast("Manual speaker address must be a private IPv4 address"))
            }
        }
        // Keep any IPs we already know about as a fallback.
        for group in groups {
            for member in group.members { ips.insert(member.ip) }
        }

        guard !ips.isEmpty else {
            emit(.discovery(.none))
            return
        }
        systemLog.info("Discovery candidates: \(ips.count)")

        // One reachable player bootstraps everything: topology comes from the player.
        var bootstrapped = false
        for ip in ips {
            if await refreshTopology(via: ip) {
                bootstrapped = true
                break
            }
        }
        guard bootstrapped else {
            emit(.discovery(.none))
            return
        }

        emit(.discovery(.found(groups.count)))

        if selectedGroupID == nil || !groups.contains(where: { $0.id == selectedGroupID }) {
            let preferred = preferredRoom.flatMap { room in
                groups.first { $0.coordinator?.roomName == room }
            }
            selectedGroupID = (preferred ?? groups.first)?.id
        }
        emit(.groups(groups, selectedID: selectedGroupID))

        await loadServices()
        await startEventServerIfNeeded()
        await resubscribe()
        startPolling()
        await pollOnce()
    }

    @discardableResult
    private func refreshTopology(via ip: String) async -> Bool {
        do {
            let result = try await soap.call(ip: ip, service: .zoneGroupTopology, action: "GetZoneGroupState")
            guard let stateXML = result["ZoneGroupState"], !stateXML.isEmpty else { return false }
            let parsed = ZoneGroupParser.parse(stateXML)
            guard !parsed.isEmpty else { return false }
            groups = parsed.sorted { $0.displayName < $1.displayName }
            return true
        } catch {
            systemLog.debug("Topology via \(ip) failed: \(String(describing: error))")
            return false
        }
    }

    private func loadServices() async {
        guard let anyIP = groups.first?.members.first?.ip else { return }
        do {
            let result = try await soap.call(ip: anyIP, service: .musicServices, action: "ListAvailableServices")
            if let list = result["AvailableServiceDescriptorList"] {
                services = ServiceListParser.parse(list)
                if let pandora = services.first(where: { $0.name == "Pandora" }) {
                    pandoraServiceID = pandora.id
                }
                emit(.services(services))
            }
        } catch {
            systemLog.debug("ListAvailableServices failed: \(String(describing: error))")
        }
    }

    public func currentPandoraServiceID() -> Int { pandoraServiceID }
    public func currentSN() -> String { lastSeenSN }

    // MARK: - Group selection

    public func selectGroup(id: String) async {
        guard selectedGroupID != id else { return }
        selectedGroupID = id
        nowPlaying = NowPlayingState()
        emit(.groups(groups, selectedID: selectedGroupID))
        await resubscribe()
        await pollOnce()
    }

    // MARK: - Transport

    public func play() async throws {
        let c = try requireCoordinator()
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "Play",
                                args: [("InstanceID", "0"), ("Speed", "1")])
        await pollOnce()
    }

    public func pause() async throws {
        let c = try requireCoordinator()
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "Pause",
                                args: [("InstanceID", "0")])
        await pollOnce()
    }

    public func next() async throws {
        let c = try requireCoordinator()
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "Next",
                                args: [("InstanceID", "0")])
        await pollOnce()
    }

    public func previous() async throws {
        let c = try requireCoordinator()
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "Previous",
                                args: [("InstanceID", "0")])
        await pollOnce()
    }

    // MARK: - Volume

    public func setVolume(_ value: Int) async throws {
        let group = selectedGroup
        let c = try requireCoordinator()
        volume = value
        if let group, group.members.count > 1 {
            // Sonos scales members against a snapshot of the per-room mix.
            // Without a fresh snapshot at the start of each adjustment burst it
            // scales against a STALE mix and reverts any trims made since.
            if Date().timeIntervalSince(lastGroupVolumeSetAt) > 1.5 {
                _ = try? await soap.call(ip: c.ip, service: .groupRenderingControl,
                                         action: "SnapshotGroupVolume",
                                         args: [("InstanceID", "0")])
            }
            lastGroupVolumeSetAt = Date()
            _ = try await soap.call(ip: c.ip, service: .groupRenderingControl, action: "SetGroupVolume",
                                    args: [("InstanceID", "0"), ("DesiredVolume", String(value))])
        } else {
            _ = try await soap.call(ip: c.ip, service: .renderingControl, action: "SetVolume",
                                    args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(value))])
        }
    }

    /// Sets one member's own volume (trim within a group).
    public func setMemberVolume(_ value: Int, device: SonosDevice) async throws {
        memberVols[device.udn] = value
        _ = try await soap.call(ip: device.ip, service: .renderingControl, action: "SetVolume",
                                args: [("InstanceID", "0"), ("Channel", "Master"),
                                       ("DesiredVolume", String(value))])
    }

    public func setMute(_ mute: Bool) async throws {
        let group = selectedGroup
        let c = try requireCoordinator()
        muted = mute
        if let group, group.members.count > 1 {
            _ = try await soap.call(ip: c.ip, service: .groupRenderingControl, action: "SetGroupMute",
                                    args: [("InstanceID", "0"), ("DesiredMute", mute ? "1" : "0")])
        } else {
            _ = try await soap.call(ip: c.ip, service: .renderingControl, action: "SetMute",
                                    args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", mute ? "1" : "0")])
        }
        emit(.volume(volume, muted: muted))
    }

    // MARK: - Browse

    public func browse(objectID: String) async throws -> [DIDLItem] {
        let c = try requireCoordinator()
        var items: [DIDLItem] = []
        var start = 0
        while true {
            let result = try await soap.call(ip: c.ip, service: .contentDirectory, action: "Browse", args: [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", String(start)),
                ("RequestedCount", "100"),
                ("SortCriteria", ""),
            ])
            let didl = result["Result"] ?? ""
            let page = DIDLParser.parse(didl)
            items.append(contentsOf: page)
            let total = Int(result["TotalMatches"] ?? "0") ?? 0
            let returned = Int(result["NumberReturned"] ?? "0") ?? page.count
            start += returned
            if returned == 0 || start >= total { break }
        }
        return items
    }

    public func browseFavorites() async throws -> [DIDLItem] {
        let favorites = try await browse(objectID: "FV:2")
        cachedFavorites = favorites
        for fav in favorites { captureSN(from: fav.res) }
        return favorites
    }

    public func browsePlaylists() async throws -> [DIDLItem] {
        try await browse(objectID: "SQ:")
    }

    // MARK: - Playback of saved content

    public func playFavorite(_ item: DIDLItem) async throws {
        switch FavoriteClassifier.classify(res: item.res) {
        case .stream:
            try await playStream(item)
        case .container:
            try await playContainer(item)
        case .unknown:
            do {
                try await playStream(item)
            } catch {
                try await playContainer(item)
            }
        }
        captureSN(from: item.res)
        await pollOnce()
    }

    private func playStream(_ item: DIDLItem) async throws {
        let c = try requireCoordinator()
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "SetAVTransportURI", args: [
            ("InstanceID", "0"),
            ("CurrentURI", item.res),
            ("CurrentURIMetaData", item.resMD),
        ])
        try await play()
    }

    private func playContainer(_ item: DIDLItem) async throws {
        let c = try requireCoordinator()
        // Favorites carry authoritative resMD; SQ: playlists don't — use the
        // standard saved-queue metadata convention for those.
        var metadata = item.resMD
        if metadata.isEmpty {
            metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
                + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
                + " xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\""
                + " xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
                + "<item id=\"\(XMLText.escape(item.id))\" parentID=\"SQ:\" restricted=\"true\">"
                + "<dc:title>\(XMLText.escape(item.title))</dc:title>"
                + "<upnp:class>object.container.playlistContainer</upnp:class>"
                + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">"
                + "RINCON_AssociatedZPUDN</desc></item></DIDL-Lite>"
        }
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "RemoveAllTracksFromQueue",
                                args: [("InstanceID", "0")])
        let added = try await soap.call(ip: c.ip, service: .avTransport, action: "AddURIToQueue", args: [
            ("InstanceID", "0"),
            ("EnqueuedURI", item.res),
            ("EnqueuedURIMetaData", metadata),
            ("DesiredFirstTrackNumberEnqueued", "0"),
            ("EnqueueAsNext", "0"),
        ])
        let firstTrack = added["FirstTrackNumberEnqueued"] ?? "1"
        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "SetAVTransportURI", args: [
            ("InstanceID", "0"),
            ("CurrentURI", "x-rincon-queue:\(c.udn)#0"),
            ("CurrentURIMetaData", ""),
        ])
        _ = try? await soap.call(ip: c.ip, service: .avTransport, action: "Seek", args: [
            ("InstanceID", "0"),
            ("Unit", "TRACK_NR"),
            ("Target", firstTrack),
        ])
        try await play()
    }

    /// Plays a Pandora station by id. Prefers a matching Sonos Favorite's stored
    /// res + resMD; otherwise constructs the URI + DIDL per the Sonos convention.
    public func playPandoraStation(stationID: String, name: String) async throws {
        if cachedFavorites.isEmpty {
            cachedFavorites = (try? await browse(objectID: "FV:2")) ?? []
        }
        let needle = "st%3a\(stationID.lowercased())"
        if let fav = cachedFavorites.first(where: { $0.res.lowercased().contains(needle) }) {
            try await playFavorite(fav)
            return
        }

        let c = try requireCoordinator()
        let sid = pandoraServiceID
        let serviceType = sid * 256 + 7
        let uri = "x-sonosapi-radio:ST%3a\(stationID)?sid=\(sid)&flags=8300&sn=\(lastSeenSN)"
        let metadata = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\""
            + " xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\""
            + " xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
            + "<item id=\"100c206cST%3a\(stationID)\" parentID=\"0\" restricted=\"true\">"
            + "<dc:title>\(XMLText.escape(name))</dc:title>"
            + "<upnp:class>object.item.audioItem.audioBroadcast.#station</upnp:class>"
            + "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">"
            + "SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>"

        _ = try await soap.call(ip: c.ip, service: .avTransport, action: "SetAVTransportURI", args: [
            ("InstanceID", "0"),
            ("CurrentURI", uri),
            ("CurrentURIMetaData", metadata),
        ])
        try await play()
    }

    private func captureSN(from uri: String) {
        guard uri.lowercased().hasPrefix("x-sonosapi-radio:") else { return }
        if let sn = SonosURI.queryParam("sn", in: uri) { lastSeenSN = sn }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let interval = await self.eventsHealthy ? 5.0 : 1.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func pollOnce() async {
        guard let c = coordinator else { return }
        do {
            var np = nowPlaying

            let transport = try await soap.call(ip: c.ip, service: .avTransport, action: "GetTransportInfo",
                                                args: [("InstanceID", "0")])
            np.transport = TransportState(rawValue: transport["CurrentTransportState"] ?? "") ?? .stopped

            let position = try await soap.call(ip: c.ip, service: .avTransport, action: "GetPositionInfo",
                                               args: [("InstanceID", "0")])
            np.trackURI = position["TrackURI"] ?? ""
            np.relTime = position["RelTime"] ?? ""
            np.duration = position["TrackDuration"] ?? ""
            if let metadata = position["TrackMetaData"], metadata.hasPrefix("<") {
                applyTrackDIDL(metadata, to: &np, coordinatorIP: c.ip)
            } else if position["TrackMetaData"] == "NOT_IMPLEMENTED" || np.trackURI.isEmpty {
                np.title = ""; np.artist = ""; np.album = ""; np.artURL = nil
            }

            let media = try await soap.call(ip: c.ip, service: .avTransport, action: "GetMediaInfo",
                                            args: [("InstanceID", "0")])
            np.stationURI = media["CurrentURI"] ?? ""
            captureSN(from: np.stationURI)
            if let mediaMD = media["CurrentURIMetaData"], mediaMD.hasPrefix("<"),
               let stationItem = DIDLParser.parse(mediaMD).first {
                np.stationName = stationItem.title
            } else if !np.stationURI.hasPrefix("x-sonosapi") && !np.stationURI.hasPrefix("x-rincon-mp3radio") && !np.stationURI.hasPrefix("hls-radio") {
                np.stationName = ""
            }

            if np != nowPlaying {
                nowPlaying = np
                emit(.nowPlaying(np))
            }

            try await pollVolume(coordinator: c)

            pollFailures = 0
            if !reachable {
                reachable = true
                emit(.reachable(true))
            }
        } catch {
            pollFailures += 1
            if pollFailures >= 2, reachable {
                reachable = false
                emit(.reachable(false))
            }
        }
    }

    private func pollVolume(coordinator c: SonosDevice) async throws {
        let multi = (selectedGroup?.members.count ?? 1) > 1
        let vol: [String: String]
        let mute: [String: String]
        if multi {
            vol = try await soap.call(ip: c.ip, service: .groupRenderingControl, action: "GetGroupVolume",
                                      args: [("InstanceID", "0")])
            mute = try await soap.call(ip: c.ip, service: .groupRenderingControl, action: "GetGroupMute",
                                       args: [("InstanceID", "0")])
        } else {
            vol = try await soap.call(ip: c.ip, service: .renderingControl, action: "GetVolume",
                                      args: [("InstanceID", "0"), ("Channel", "Master")])
            mute = try await soap.call(ip: c.ip, service: .renderingControl, action: "GetMute",
                                       args: [("InstanceID", "0"), ("Channel", "Master")])
        }
        let newVolume = Int(vol["CurrentVolume"] ?? "") ?? volume
        let newMuted = (mute["CurrentMute"] ?? "0") == "1"
        if newVolume != volume || newMuted != muted {
            volume = newVolume
            muted = newMuted
            emit(.volume(volume, muted: muted))
        }

        // Per-member trim volumes for grouped rooms.
        if multi, let members = selectedGroup?.members {
            var vols: [String: Int] = [:]
            for member in members {
                if let result = try? await soap.call(ip: member.ip, service: .renderingControl,
                                                     action: "GetVolume",
                                                     args: [("InstanceID", "0"), ("Channel", "Master")]),
                   let v = Int(result["CurrentVolume"] ?? "") {
                    vols[member.udn] = v
                }
            }
            if !vols.isEmpty, vols != memberVols {
                memberVols = vols
                emit(.memberVolumes(vols))
            }
        }
    }

    private func applyTrackDIDL(_ didl: String, to np: inout NowPlayingState, coordinatorIP: String) {
        guard let item = DIDLParser.parse(didl).first else { return }
        np.title = item.title
        np.artist = item.artist
        np.album = item.album
        np.artURL = item.artURL(via: coordinatorIP)
        np.rating = item.rating
    }

    // MARK: - Eventing

    private func startEventServerIfNeeded() async {
        guard eventServer == nil else { return }
        let server = EventHTTPServer { [weak self] sid, body in
            guard let self else { return }
            Task { await self.handleNotify(sid: sid, body: body) }
        }
        do {
            eventPort = try await server.start()
            eventServer = server
            systemLog.info("Event server listening on port \(self.eventPort)")
        } catch {
            systemLog.error("Event server failed to start: \(String(describing: error))")
            setEventsHealthy(false)
        }
    }

    private func resubscribe() async {
        for task in renewTasks { task.cancel() }
        renewTasks = []
        let old = subscriptions
        subscriptions = []
        sidKinds = [:]
        for sub in old {
            await GENA.unsubscribe(sub)
        }

        guard let c = coordinator, eventServer != nil, eventPort > 0,
              let macIP = LocalIP.matching(peer: c.ip) else {
            setEventsHealthy(false)
            return
        }
        let callback = "http://\(macIP):\(eventPort)/notify"
        let group = selectedGroup
        let renderingService: SonosUPnPService =
            (group?.members.count ?? 1) > 1 ? .groupRenderingControl : .renderingControl

        var healthy = true
        for service in [SonosUPnPService.avTransport, renderingService, .zoneGroupTopology] {
            do {
                let sub = try await GENA.subscribe(ip: c.ip, path: service.eventPath, callbackURL: callback)
                subscriptions.append(sub)
                sidKinds[sub.sid] = service
                startRenewal(for: sub)
            } catch {
                systemLog.error("Subscription failed for \(service.eventPath): \(String(describing: error))")
                healthy = false
            }
        }
        setEventsHealthy(healthy && !subscriptions.isEmpty)
    }

    private func startRenewal(for sub: GENA.Subscription) {
        let task = Task { [weak self] in
            var current = sub
            while !Task.isCancelled {
                let wait = max(30, current.timeoutSeconds / 2)
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                if Task.isCancelled { return }
                do {
                    current = try await GENA.renew(current)
                } catch {
                    await self?.renewalFailed(sid: current.sid)
                    return
                }
            }
        }
        renewTasks.append(task)
    }

    private func renewalFailed(sid: String) {
        subscriptions.removeAll { $0.sid == sid }
        sidKinds[sid] = nil
        setEventsHealthy(false)
    }

    private func setEventsHealthy(_ healthy: Bool) {
        guard eventsHealthy != healthy else { return }
        eventsHealthy = healthy
        emit(.eventsHealthy(healthy))
    }

    private func handleNotify(sid: String, body: String) async {
        guard let kind = EventNotificationRouter.service(for: sid, in: sidKinds) else {
            systemLog.debug("Ignored GENA notification with an unknown subscription")
            return
        }
        let props = FlatXMLParser.parse(body)

        if EventNotificationRouter.acceptsLastChange(kind),
           let lastChange = props["LastChange"], !lastChange.isEmpty {
            let changes = LastChangeParser.parse(lastChange)
            var np = nowPlaying
            var dirty = false
            if let state = changes["TransportState"], let ts = TransportState(rawValue: state) {
                np.transport = ts; dirty = true
            }
            if let uri = changes["CurrentTrackURI"] { np.trackURI = uri; dirty = true }
            if let metadata = changes["CurrentTrackMetaData"], metadata.hasPrefix("<"),
               let c = coordinator {
                applyTrackDIDL(metadata, to: &np, coordinatorIP: c.ip)
                dirty = true
            }
            if let duration = changes["CurrentTrackDuration"] { np.duration = duration; dirty = true }
            if dirty, np != nowPlaying {
                nowPlaying = np
                emit(.nowPlaying(np))
            }
            if let v = changes["Volume"], let newVolume = Int(v) {
                if newVolume != volume { volume = newVolume; emit(.volume(volume, muted: muted)) }
            }
            if let m = changes["Mute"] {
                let newMuted = m == "1"
                if newMuted != muted { muted = newMuted; emit(.volume(volume, muted: muted)) }
            }
        }

        if kind == .groupRenderingControl,
           let gv = props["GroupVolume"], let newVolume = Int(gv), newVolume != volume {
            volume = newVolume
            emit(.volume(volume, muted: muted))
        }
        if kind == .groupRenderingControl, let gm = props["GroupMute"] {
            let newMuted = gm == "1"
            if newMuted != muted { muted = newMuted; emit(.volume(volume, muted: muted)) }
        }

        if kind == .zoneGroupTopology, let stateXML = props["ZoneGroupState"], !stateXML.isEmpty {
            let parsed = ZoneGroupParser.parse(stateXML)
            if !parsed.isEmpty {
                groups = parsed.sorted { $0.displayName < $1.displayName }
                if !groups.contains(where: { $0.id == selectedGroupID }) {
                    selectedGroupID = groups.first?.id
                    await resubscribe()
                }
                emit(.groups(groups, selectedID: selectedGroupID))
            }
        }
    }

    // MARK: - Grouping

    /// Pulls a player into the currently selected group.
    public func joinCurrentGroup(device: SonosDevice) async throws {
        let c = try requireCoordinator()
        guard device.udn != c.udn else { return }
        _ = try await soap.call(ip: device.ip, service: .avTransport, action: "SetAVTransportURI", args: [
            ("InstanceID", "0"),
            ("CurrentURI", "x-rincon:\(c.udn)"),
            ("CurrentURIMetaData", ""),
        ])
        await regroupCompleted()
    }

    /// Splits a player out of its group (it becomes a standalone room).
    public func removeFromGroup(device: SonosDevice) async throws {
        _ = try await soap.call(ip: device.ip, service: .avTransport,
                                action: "BecomeCoordinatorOfStandaloneGroup",
                                args: [("InstanceID", "0")])
        await regroupCompleted()
    }

    /// Re-reads topology after a membership change. Group IDs change when
    /// membership does, so re-select by coordinator UDN.
    private func regroupCompleted() async {
        let previousCoordinator = coordinator?.udn
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let ip = coordinator?.ip ?? groups.first?.members.first?.ip {
            _ = await refreshTopology(via: ip)
        }
        if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = groups.first { $0.coordinatorUDN == previousCoordinator }?.id
                ?? groups.first { group in group.members.contains { $0.udn == previousCoordinator } }?.id
                ?? groups.first?.id
        }
        emit(.groups(groups, selectedID: selectedGroupID))
        await resubscribe()
        await pollOnce()
    }

    // MARK: - Thumbs via the player's local control websocket

    /// Rates the currently playing track through the player's own music-service
    /// session (the official-app mechanism). Returns true if the track should
    /// be considered skipped by the service (thumbs-down auto-skip).
    public func rateCurrentTrack(thumbsUp: Bool) async throws {
        guard let group = selectedGroup, let c = group.coordinator else {
            throw SonosError(message: "No Sonos group selected")
        }
        _ = try await muse.rateCurrentTrack(ip: c.ip, groupId: group.id, thumbsUp: thumbsUp)
    }

    // MARK: - Pandora SMAPI (thumbs on cloud-queue firmware)

    /// Household id + Sonos-style device id for the current coordinator.
    public func smapiIdentity() -> (householdId: String, deviceId: String)? {
        guard let c = coordinator else { return nil }
        // householdId is fetched async by the caller via PandoraSMAPI.householdId;
        // here we only supply the deviceId derived from the coordinator UDN.
        return (c.udn, PandoraSMAPI.deviceId(fromUDN: c.udn))
    }

    public func smapiHouseholdId() async -> String? {
        guard let c = coordinator else { return nil }
        return await PandoraSMAPI.householdId(ip: c.ip)
    }

    public func smapiBeginLink() async throws -> SMAPIDeviceLink {
        guard let c = coordinator else { throw SonosError(message: "No Sonos group selected") }
        guard let household = await PandoraSMAPI.householdId(ip: c.ip) else {
            throw SonosError(message: "Could not read Sonos household id")
        }
        let deviceId = PandoraSMAPI.deviceId(fromUDN: c.udn)
        return try await smapi.getAppLink(householdId: household, deviceId: deviceId)
    }

    public func smapiPollToken(link: SMAPIDeviceLink) async throws -> SMAPICredentials {
        try await smapi.getDeviceAuthToken(link: link)
    }

    /// Rates the currently playing track. Returns whether Sonos should skip.
    @discardableResult
    public func smapiRateCurrent(rating: SMAPIRating,
                                 credentials: SMAPICredentials) async throws -> Bool {
        guard let itemID = PandoraSMAPI.itemID(fromTrackURI: nowPlaying.trackURI) else {
            throw SonosError(message: "No rateable track playing")
        }
        return try await smapi.rateItem(id: itemID, rating: rating, credentials: credentials)
    }

    public func shutdown() async {
        pollTask?.cancel()
        for task in renewTasks { task.cancel() }
        for sub in subscriptions { await GENA.unsubscribe(sub) }
        subscriptions = []
        eventServer?.stop()
        eventServer = nil
    }
}

enum EventNotificationRouter {
    static func service(for sid: String,
                        in routes: [String: SonosUPnPService]) -> SonosUPnPService? {
        routes[sid]
    }

    static func acceptsLastChange(_ service: SonosUPnPService) -> Bool {
        service == .avTransport || service == .renderingControl
    }
}
