import Foundation
import os
import Testing
@testable import PandoraKit

@Suite(.serialized) struct PandoraSessionTests {
    @Test func cachedSessionBelongsToOneAccount() throws {
        let cached = PandoraClient.WebSession(username: "first@example.invalid", csrf: "csrf", auth: "token")
        let data = try JSONEncoder().encode(cached)
        #expect(PandoraClient.WebSession.decode(data, for: "first@example.invalid")?.auth == "token")
        #expect(PandoraClient.WebSession.decode(data, for: "second@example.invalid") == nil)
        // Old unscoped caches must force one fresh login instead of silently
        // attaching another person's session to the newly configured account.
        #expect(PandoraClient.WebSession.decode(Data(#"{"csrf":"csrf","auth":"token"}"#.utf8),
                                               for: "first@example.invalid") == nil)
    }

    @Test func feedbackParsesJSONInsteadOfWhitespace() {
        #expect(PandoraClient.feedbackSucceeded("""
        {"data": {"feedback": {"setFeedback": {"status": "OK"}}}, "errors": []}
        """))
        #expect(!PandoraClient.feedbackSucceeded(#"{"data":{"feedback":{"setFeedback":{"status":"OK"}}},"errors":[{"message":"failed"}]}"#))
        #expect(!PandoraClient.feedbackSucceeded(#"{"unrelated":{"status":"OK"}}"#))
        #expect(!PandoraClient.feedbackSucceeded("not JSON"))
    }

    @Test func removingAccountRejectsInFlightLogin() async throws {
        let gate = LoginResponseGate()
        PandoraSessionURLProtocol.handler.withLock { $0 = { _ in
            await gate.pause()
            let syncTime = try PandoraCrypto.encrypt("junk1700000000", key: PandoraCrypto.decryptKey)
            return try JSONSerialization.data(withJSONObject: ["stat": "ok", "result": [
                "partnerId": "partner", "partnerAuthToken": "partner-token", "syncTime": syncTime,
            ]])
        } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PandoraSessionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            PandoraSessionURLProtocol.handler.withLock { $0 = nil }
        }
        // The injected client disables persistent storage; this test never
        // reads, modifies, or prompts for the user's real Keychain.
        let client = PandoraClient(urlSession: session, webSession: session)
        await client.setCredentials(username: "test@example.invalid", password: "test-only")
        let login = Task { try await client.verify() }
        await gate.waitForRequest()
        await client.clearCredentials()
        await gate.resume()
        do {
            _ = try await login.value
            Issue.record("The removed account's login should be discarded")
        } catch is CancellationError {
            // Expected: no user login follows the stale partner response.
        }
        #expect(await client.isConfigured == false)
    }

    @Test func failedFeedbackDoesNotRetryUnderReplacementAccount() async throws {
        let gate = LoginResponseGate()
        let cached = try JSONEncoder().encode(PandoraClient.WebSession(
            username: "first@example.invalid", csrf: "test-csrf", auth: "test-token"))
        PandoraSessionURLProtocol.handler.withLock { $0 = { _ in
            await gate.pause()
            throw URLError(.networkConnectionLost)
        } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PandoraSessionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            session.invalidateAndCancel()
            PandoraSessionURLProtocol.handler.withLock { $0 = nil }
        }
        let client = PandoraClient(urlSession: session, webSession: session,
                                   webSessionCache: .init(load: { cached }, save: { _ in }, delete: {}))
        await client.setCredentials(username: "first@example.invalid", password: "test-only")
        let feedback = Task {
            try await client.addFeedback(ref: .modern(trackId: "TR:1", stationId: "2"), isPositive: true)
        }
        await gate.waitForRequest()
        await client.setCredentials(username: "second@example.invalid", password: "test-only")
        await gate.resume()
        do {
            try await feedback.value
            Issue.record("A failed request must not retry for the replacement account")
        } catch is CancellationError {
        }
        #expect(await gate.requestCount == 1)
    }
}

private actor LoginResponseGate {
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    var response: CheckedContinuation<Void, Never>?
    var requestCount = 0

    func pause() async {
        requestCount += 1
        if entered { return }
        entered = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { response = $0 }
    }

    func waitForRequest() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        response?.resume()
        response = nil
    }
}

private final class PandoraSessionURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> Data
    static let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.handler.withLock { $0 }
        Task {
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                let data = try await handler(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}
