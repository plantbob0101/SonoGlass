import Foundation
import os

private let pandoraLog = Logger(subsystem: "com.sonoglass", category: "pandora")

public struct PandoraStation: Sendable, Hashable, Identifiable {
    public var id: String { stationId }
    public let stationId: String
    public let stationToken: String
    public let stationName: String
    public let artUrl: String?

    public init(stationId: String, stationToken: String, stationName: String, artUrl: String?) {
        self.stationId = stationId
        self.stationToken = stationToken
        self.stationName = stationName
        self.artUrl = artUrl
    }
}

/// Pandora JSON API v5 client (tuner.pandora.com) — the pianobar/pithos/anesidora lineage.
public actor PandoraClient {
    private struct Session {
        let partnerId: String
        let partnerAuthToken: String
        let userId: String
        let userAuthToken: String
        let syncTimeOffset: Int
    }

    private static let base = "https://tuner.pandora.com/services/json/"
    private static let partnerUsername = "android"
    private static let partnerPassword = "AC7IBG09A3DTSYM4R41UJWL07VLN8JI7"
    private static let deviceModel = "android-generic"
    private static let version = "5"

    private var credentials: (username: String, password: String)?
    private var session: Session?
    private let urlSession: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)
    }

    public func setCredentials(username: String, password: String) {
        credentials = (username, password)
        session = nil
    }

    public func clearCredentials() {
        credentials = nil
        session = nil
    }

    public var isConfigured: Bool { credentials != nil }

    /// Performs a full login; throws with Pandora's message on failure.
    @discardableResult
    public func verify() async throws -> Bool {
        session = nil
        _ = try await ensureSession()
        return true
    }

    public func addFeedback(stationToken: String, trackToken: String, isPositive: Bool) async throws {
        _ = try await authenticatedCall(method: "station.addFeedback", params: [
            "stationToken": stationToken,
            "trackToken": trackToken,
            "isPositive": isPositive,
        ])
        pandoraLog.info("addFeedback ok (positive=\(isPositive))")
    }

    public func stationList() async throws -> [PandoraStation] {
        let result = try await authenticatedCall(method: "user.getStationList", params: [
            "includeStationArtUrl": true,
        ])
        guard let stations = result["stations"] as? [[String: Any]] else {
            throw PandoraError.badResponse("no stations array")
        }
        // Keep the API's order (QuickMix / Thumbprint first).
        return stations.compactMap { s in
            guard let id = s["stationId"] as? String,
                  let token = s["stationToken"] as? String,
                  let name = s["stationName"] as? String else { return nil }
            return PandoraStation(stationId: id, stationToken: token, stationName: name,
                                  artUrl: s["artUrl"] as? String)
        }
    }

    // MARK: - Session plumbing

    private func ensureSession() async throws -> Session {
        if let session { return session }
        guard let credentials else { throw PandoraError.notConfigured }

        // 1. Partner login — plain JSON body.
        let partnerBody: [String: Any] = [
            "username": Self.partnerUsername,
            "password": Self.partnerPassword,
            "deviceModel": Self.deviceModel,
            "version": Self.version,
        ]
        let partnerResult = try await rawCall(query: [("method", "auth.partnerLogin")],
                                              body: partnerBody, encrypted: false)
        guard let partnerId = partnerResult["partnerId"] as? String,
              let partnerAuthToken = partnerResult["partnerAuthToken"] as? String,
              let syncTimeHex = partnerResult["syncTime"] as? String else {
            throw PandoraError.badResponse("partnerLogin missing fields")
        }
        let decrypted = try PandoraCrypto.decrypt(syncTimeHex)
        guard let serverSyncTime = PandoraCrypto.decodeSyncTime(decrypted) else {
            throw PandoraError.badResponse("bad syncTime")
        }
        let syncTimeOffset = serverSyncTime - Int(Date().timeIntervalSince1970)

        // 2. User login — encrypted body.
        let userBody: [String: Any] = [
            "loginType": "user",
            "username": credentials.username,
            "password": credentials.password,
            "partnerAuthToken": partnerAuthToken,
            "syncTime": syncTimeOffset + Int(Date().timeIntervalSince1970),
        ]
        let userResult = try await rawCall(query: [
            ("method", "auth.userLogin"),
            ("auth_token", partnerAuthToken),
            ("partner_id", partnerId),
        ], body: userBody, encrypted: true)
        guard let userId = userResult["userId"] as? String,
              let userAuthToken = userResult["userAuthToken"] as? String else {
            throw PandoraError.badResponse("userLogin missing fields")
        }

        let s = Session(partnerId: partnerId, partnerAuthToken: partnerAuthToken,
                        userId: userId, userAuthToken: userAuthToken,
                        syncTimeOffset: syncTimeOffset)
        session = s
        pandoraLog.info("Pandora login ok")
        return s
    }

    private func authenticatedCall(method: String, params: [String: Any]) async throws -> [String: Any] {
        do {
            return try await authenticatedCallOnce(method: method, params: params)
        } catch PandoraError.api(let code, _) where code == 1001 {
            // Auth token expired — re-login once and retry.
            pandoraLog.info("Pandora session expired; re-authenticating")
            session = nil
            return try await authenticatedCallOnce(method: method, params: params)
        }
    }

    private func authenticatedCallOnce(method: String, params: [String: Any]) async throws -> [String: Any] {
        let s = try await ensureSession()
        var body = params
        body["userAuthToken"] = s.userAuthToken
        body["syncTime"] = s.syncTimeOffset + Int(Date().timeIntervalSince1970)
        return try await rawCall(query: [
            ("method", method),
            ("auth_token", s.userAuthToken),
            ("partner_id", s.partnerId),
            ("user_id", s.userId),
        ], body: body, encrypted: true)
    }

    private func rawCall(query: [(String, String)], body: [String: Any],
                         encrypted: Bool) async throws -> [String: Any] {
        var components = URLComponents(string: Self.base)!
        // Strict percent-encoding: Pandora auth tokens contain '+' and '=' which
        // must not survive unencoded in the query string.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQuery = query.map { name, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(encoded)"
        }.joined(separator: "&")

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        if encrypted {
            let hex = try PandoraCrypto.encrypt(String(decoding: jsonData, as: UTF8.self))
            request.httpBody = Data(hex.utf8)
        } else {
            request.httpBody = jsonData
        }

        let (data, _) = try await urlSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stat = json["stat"] as? String else {
            throw PandoraError.badResponse("not JSON")
        }
        if stat == "ok" {
            return json["result"] as? [String: Any] ?? [:]
        }
        let code = json["code"] as? Int ?? -1
        let message = json["message"] as? String ?? "unknown error"
        throw PandoraError.api(code: code, message: message)
    }
}
