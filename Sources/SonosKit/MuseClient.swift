import Foundation
import os

private let museLog = Logger(subsystem: "com.sonoglass", category: "muse")

/// Minimal client for the Sonos player's local control websocket
/// (wss://{ip}:1443/websocket/api). This is the surface the official Sonos app
/// uses; notably it carries `playbackMetadata:1 → rate`, which makes the
/// player submit a track rating through its own music-service session —
/// no service credentials required in the controller.
public actor MuseClient {

    public struct Response {
        public let success: Bool
        public let headerJSON: [String: Any]
        public let bodyJSON: [String: Any]

        public var errorReason: String? {
            guard !success else { return nil }
            let code = bodyJSON["errorCode"] as? String ?? "ERROR"
            let reason = bodyJSON["reason"] as? String ?? ""
            return reason.isEmpty ? code : "\(code): \(reason)"
        }
    }

    private final class TrustLocalPlayer: NSObject, URLSessionDelegate {
        // Sonos players use self-signed certificates on 1443; accept them for
        // this session (which only ever talks to LAN speakers).
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config, delegate: TrustLocalPlayer(), delegateQueue: nil)
    }

    /// One-shot command: connect, send [header, body], await first response, close.
    public func command(ip: String, namespace: String, command: String,
                        groupId: String, body: [String: Any] = [:]) async throws -> Response {
        var request = URLRequest(url: URL(string: "wss://\(ip):1443/websocket/api")!)
        request.setValue("123e4567-e89b-12d3-a456-426655440000", forHTTPHeaderField: "X-Sonos-Api-Key")
        request.setValue("v1.api.smartspeaker.audio", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let header: [String: Any] = [
            "namespace": namespace,
            "command": command,
            "groupId": groupId,
        ]
        let payload = try JSONSerialization.data(withJSONObject: [header, body])
        let message = String(decoding: payload, as: UTF8.self)

        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        try await task.send(.string(message))
        let reply = try await task.receive()

        let text: String
        switch reply {
        case .string(let s): text = s
        case .data(let d): text = String(decoding: d, as: UTF8.self)
        @unknown default: text = ""
        }
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
              array.count >= 2 else {
            throw SonosError(message: "Unexpected response from player websocket")
        }
        let success = (array[0]["success"] as? Bool) ?? false
        return Response(success: success, headerJSON: array[0], bodyJSON: array[1])
    }

    /// The player-reported current queue item id (rate exactly what's playing).
    public func currentItemId(ip: String, groupId: String) async throws -> String? {
        let response = try await command(ip: ip, namespace: "playbackMetadata:1",
                                         command: "getMetadataStatus", groupId: groupId)
        guard response.success else {
            throw SonosError(message: response.errorReason ?? "getMetadataStatus failed")
        }
        let current = response.bodyJSON["currentItem"] as? [String: Any]
        return current?["id"] as? String
    }

    /// Rates the current track through the player's own service session.
    /// Returns the rating connotation the player reports back.
    @discardableResult
    public func rateCurrentTrack(ip: String, groupId: String,
                                 thumbsUp: Bool) async throws -> String {
        guard let itemId = try await currentItemId(ip: ip, groupId: groupId) else {
            throw SonosError(message: "Nothing playing to rate")
        }
        let response = try await command(
            ip: ip, namespace: "playbackMetadata:1", command: "rate", groupId: groupId,
            body: ["itemId": itemId, "rating": ["type": thumbsUp ? "THUMBSUP" : "THUMBSDOWN"]]
        )
        guard response.success else {
            museLog.error("rate failed: \(response.errorReason ?? "?", privacy: .public)")
            throw SonosError(message: response.errorReason ?? "Rating failed")
        }
        let rating = response.bodyJSON["rating"] as? [String: Any]
        let connotation = rating?["connotation"] as? String ?? "UNKNOWN"
        museLog.info("rate ok: \(connotation, privacy: .public)")
        return connotation
    }
}
