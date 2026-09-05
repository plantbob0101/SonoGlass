import Foundation
import Testing
@testable import SonosKit

/// Deterministically holds a player response while a second actor call changes
/// selection. Every request stays inside URLProtocol; no LAN access is made.
private actor SOAPLifecycleFixture {
    private var requests: [URLRequest] = []
    private var held = false
    private var release: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private let heldAction: String?
    private var didHold = false

    init(holdFirstTransport: Bool = false, heldAction: String? = nil) {
        self.heldAction = holdFirstTransport ? "#GetTransportInfo" : heldAction
    }

    func response(for request: URLRequest) async -> String {
        requests.append(request)
        let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
        if let heldAction, !didHold, action.contains(heldAction) {
            didHold = true
            held = true
            waiting?.resume()
            waiting = nil
            await withCheckedContinuation { release = $0 }
        }
        let content: String
        if action.contains("#GetTransportInfo") {
            content = "<CurrentTransportState>PLAYING</CurrentTransportState>"
        } else if action.contains("#GetPositionInfo") {
            content = "<TrackURI>track-\(request.url?.host ?? "")</TrackURI><TrackMetaData>NOT_IMPLEMENTED</TrackMetaData>"
        } else if action.contains("#GetMediaInfo") {
            content = "<CurrentURI>queue</CurrentURI>"
        } else if action.contains("#GetVolume") || action.contains("#GetGroupVolume") {
            content = "<CurrentVolume>20</CurrentVolume>"
        } else if action.contains("#GetMute") || action.contains("#GetGroupMute") {
            content = "<CurrentMute>0</CurrentMute>"
        } else {
            content = ""
        }
        return "<response>\(content)</response>"
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func releaseResponse() {
        release?.resume()
        release = nil
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private final class SOAPLifecycleProtocol: URLProtocol, @unchecked Sendable {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var fixture: SOAPLifecycleFixture?
        func install(_ fixture: SOAPLifecycleFixture) { lock.withLock { self.fixture = fixture } }
        func current() -> SOAPLifecycleFixture? { lock.withLock { fixture } }
    }

    private static let store = Store()
    static func install(_ fixture: SOAPLifecycleFixture) { store.install(fixture) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.store.current(), let url = request.url else { return }
        Task {
            let xml = await fixture.response(for: request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/xml"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(xml.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SonosLifecycleTests {
    private func makeSystem(_ fixture: SOAPLifecycleFixture) -> SonosSystem {
        SOAPLifecycleProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SOAPLifecycleProtocol.self]
        let soap = SOAPClient(session: URLSession(configuration: configuration))
        let rooms = [
            ZoneGroup(id: "A", coordinatorUDN: "A", members: [
                SonosDevice(udn: "A", ip: "192.168.1.10", roomName: "First room"),
            ]),
            ZoneGroup(id: "B", coordinatorUDN: "B", members: [
                SonosDevice(udn: "B", ip: "192.168.1.20", roomName: "Second room"),
            ]),
        ]
        return SonosSystem(soap: soap, groups: rooms, selectedGroupID: "A")
    }

    @Test func roomSwitchDiscardsInFlightPoll() async {
        let fixture = SOAPLifecycleFixture(holdFirstTransport: true)
        let system = makeSystem(fixture)
        let oldPoll = Task { await system.pollOnce() }
        await fixture.waitUntilHeld()
        await system.selectGroup(id: "B")
        await fixture.releaseResponse()
        await oldPoll.value
        let requests = await fixture.recordedRequests()
        // The old room's transport response must not lead to position/media/
        // volume requests or state publication after the switch.
        #expect(requests.filter { $0.url?.host == "192.168.1.10" }.count == 1)
        #expect(requests.contains { $0.url?.host == "192.168.1.20" })
        await system.shutdown()
    }

    @Test func shutdownInvalidatesInFlightPoll() async {
        let fixture = SOAPLifecycleFixture(holdFirstTransport: true)
        let system = makeSystem(fixture)
        let oldPoll = Task { await system.pollOnce() }
        await fixture.waitUntilHeld()
        await system.shutdown()
        await fixture.releaseResponse()
        await oldPoll.value
        #expect(await fixture.recordedRequests().count == 1)
    }

    @Test func roomSwitchCancelsTheRemainderOfFavoritePlayback() async {
        let fixture = SOAPLifecycleFixture(heldAction: "#SetAVTransportURI")
        let system = makeSystem(fixture)
        let favorite = DIDLItem(id: "favorite", title: "Station", res: "x-sonosapi-radio:station")
        let playback = Task { try await system.playFavorite(favorite) }
        await fixture.waitUntilHeld()
        await system.selectGroup(id: "B")
        await fixture.releaseResponse()
        await #expect(throws: CancellationError.self) { try await playback.value }
        let requests = await fixture.recordedRequests()
        #expect(!requests.contains { $0.value(forHTTPHeaderField: "SOAPACTION")?.contains("#Play\"") == true })
        await system.shutdown()
    }

    @Test func delayedVolumeCannotTargetAnotherRoom() async {
        let fixture = SOAPLifecycleFixture()
        let system = makeSystem(fixture)
        await #expect(throws: CancellationError.self) {
            try await system.setVolume(75, groupID: "B")
        }
        #expect(await fixture.recordedRequests().isEmpty)
        await system.shutdown()
    }

    @Test func automaticSkipIsNotRepeatedForANewTrack() async throws {
        let fixture = SOAPLifecycleFixture()
        let system = makeSystem(fixture)
        let skipped = try await system.nextIfCurrentTrackMatches(trackURI: "previous-track", groupID: "A")
        #expect(!skipped)
        let requests = await fixture.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "SOAPACTION")?.contains("#GetPositionInfo") == true)
        await system.shutdown()
    }

    @Test func delayedSkipCannotTargetAnotherRoom() async throws {
        let fixture = SOAPLifecycleFixture()
        let system = makeSystem(fixture)
        #expect(try await !system.nextIfCurrentTrackMatches(trackURI: "old-track", groupID: "B"))
        #expect(await fixture.recordedRequests().isEmpty)
        await system.shutdown()
    }
}

@Suite struct GENAReliabilityTests {
    @Test func rejectsNonLANSubscriptionTargetsAndMalformedPaths() throws {
        #expect(throws: SonosError.self) {
            try GENA.subscriptionURL(ip: "8.8.8.8", path: "/event")
        }
        #expect(throws: SonosError.self) {
            try GENA.subscriptionURL(ip: "192.168.1.2@attacker.example", path: "/event")
        }
        for path in ["//attacker.example/event", "event", "/event?redirect=1", "/event\r\nX-Injected: yes"] {
            #expect(throws: SonosError.self) {
                try GENA.subscriptionURL(ip: "192.168.1.2", path: path)
            }
        }
        #expect(try GENA.subscriptionURL(ip: "192.168.1.2", path: "/ZoneGroupTopology/Event").absoluteString
                == "http://192.168.1.2:1400/ZoneGroupTopology/Event")
    }

    @Test func hostileTimeoutsCannotOverflowRenewalScheduling() {
        #expect(GENA.parseTimeout("Second-\(Int.max)") == 86_400)
        #expect(GENA.renewalDelay(timeoutSeconds: Int.max) == 1800)
        for header in ["Second-0", "Second--1", "garbage-3600", "Second-infinite", "Second-999999999999999999999999999"] {
            #expect(GENA.parseTimeout(header) == nil)
        }
        #expect(GENA.parseTimeout(" SECOND-60 ") == 60)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledListenerStartupCanBeRetried() async throws {
        let server = EventHTTPServer { _, _ in }
        let startup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.start()
        }
        await #expect(throws: CancellationError.self) { try await startup.value }
        let port = try await server.start()
        #expect(port > 0)
        server.stop()
    }

    @Test func shortSubscriptionsRenewBeforeTheyExpire() {
        #expect(GENA.renewalDelay(timeoutSeconds: 10) == 5)
        #expect(GENA.renewalDelay(timeoutSeconds: 1) == 0.5)
        #expect(GENA.renewalDelay(timeoutSeconds: -1) == 0.5)
    }
}
