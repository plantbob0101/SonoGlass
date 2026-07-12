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

    // Listener web session (pandora.com) — used for cloud-queue-era feedback.
    private var webCsrfToken = ""
    private var webAuthToken = ""
    private let webSession: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)

        let webConfig = URLSessionConfiguration.ephemeral
        webConfig.timeoutIntervalForRequest = 15
        webConfig.httpCookieAcceptPolicy = .always
        webConfig.httpShouldSetCookies = true
        webConfig.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        ]
        webSession = URLSession(configuration: webConfig)
    }

    public func setCredentials(username: String, password: String) {
        credentials = (username, password)
        session = nil
        webAuthToken = ""
    }

    public func clearCredentials() {
        credentials = nil
        session = nil
        webAuthToken = ""
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

    /// Format-aware feedback: legacy tokens go to the v5 tuner API, cloud-queue
    /// catalog ids go to the listener GraphQL API on pandora.com.
    public func addFeedback(ref: PandoraTrackRef, isPositive: Bool, elapsedSeconds: Int = 0) async throws {
        switch ref {
        case .legacy(let trackToken, let stationToken):
            try await addFeedback(stationToken: stationToken, trackToken: trackToken,
                                  isPositive: isPositive)
        case .modern(let trackId, let stationId):
            do {
                try await graphQLFeedback(trackId: trackId, stationId: stationId,
                                          isPositive: isPositive, elapsedSeconds: elapsedSeconds)
            } catch {
                // Session likely expired — one re-login and retry.
                webAuthToken = ""
                try await graphQLFeedback(trackId: trackId, stationId: stationId,
                                          isPositive: isPositive, elapsedSeconds: elapsedSeconds)
            }
            pandoraLog.info("GraphQL setFeedback ok (positive=\(isPositive))")
        }
    }

    // MARK: - Listener web API (pandora.com)

    private func ensureWebSession() async throws {
        guard webAuthToken.isEmpty else { return }
        guard let credentials else { throw PandoraError.notConfigured }

        // Prime cookies so pandora.com hands us a csrftoken.
        let home = URL(string: "https://www.pandora.com/")!
        _ = try? await webSession.data(from: home)
        webCsrfToken = webSession.configuration.httpCookieStorage?
            .cookies(for: home)?.first { $0.name == "csrftoken" }?.value ?? ""
        guard !webCsrfToken.isEmpty else {
            throw PandoraError.badResponse("no csrf token from pandora.com")
        }

        let (status, body) = try await webPost(path: "/api/v1/auth/login", json: [
            "username": credentials.username,
            "password": credentials.password,
            "keepLoggedIn": true,
        ])
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let token = json["authToken"] as? String else {
            if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let message = json["message"] as? String {
                throw PandoraError.api(code: json["errorCode"] as? Int ?? -1, message: message)
            }
            throw PandoraError.badResponse("web login failed (HTTP \(status))")
        }
        webAuthToken = token
        pandoraLog.info("Pandora web login ok")
    }

    private func graphQLFeedback(trackId: String, stationId: String,
                                 isPositive: Bool, elapsedSeconds: Int) async throws {
        try await ensureWebSession()
        let mutation = "mutation { feedback { setFeedback(targetId: \"\(trackId)\", "
            + "sourceContextId: \"ST:0:\(stationId)\", value: \(isPositive ? "UP" : "DOWN"), "
            + "deviceUuid: \"sonoglass\", elapsedTime: \(max(0, elapsedSeconds))) { status } } }"
        let (status, body) = try await webPost(path: "/api/v1/graphql/graphql",
                                               json: ["query": mutation])
        guard status == 200, body.contains("\"status\":\"OK\""), !body.contains("\"errors\"") else {
            pandoraLog.error("GraphQL feedback failed: HTTP \(status) body=\(body, privacy: .public) mutation=\(mutation, privacy: .public)")
            throw PandoraError.badResponse("feedback rejected: \(Self.graphQLErrorSummary(from: body, status: status))")
        }
    }

    private static func graphQLErrorSummary(from body: String, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]],
           let message = errors.first?["message"] as? String {
            return message
        }
        return "HTTP \(status): \(body.prefix(160))"
    }

    private func webPost(path: String, json: [String: Any]) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "https://www.pandora.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(webCsrfToken, forHTTPHeaderField: "X-CsrfToken")
        if !webAuthToken.isEmpty {
            request.setValue(webAuthToken, forHTTPHeaderField: "X-AuthToken")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await webSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// Recent thumbed songs for a station ("song — artist" strings, newest data
    /// Pandora returns first). Used to verify feedback landed.
    public func stationThumbs(stationToken: String, positive: Bool) async throws -> [String] {
        let result = try await authenticatedCall(method: "station.getStation", params: [
            "stationToken": stationToken,
            "includeExtendedAttributes": true,
        ])
        guard let feedback = result["feedback"] as? [String: Any],
              let list = feedback[positive ? "thumbsUp" : "thumbsDown"] as? [[String: Any]] else {
            return []
        }
        return list.map { entry in
            "\(entry["songName"] as? String ?? "?") — \(entry["artistName"] as? String ?? "?")"
        }
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
