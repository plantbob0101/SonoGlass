import Foundation
import os

private let smapiLog = Logger(subsystem: "com.sonoglass", category: "smapi")

/// Persisted Sonos Music API (SMAPI) session for Pandora, obtained via the
/// AppLink device-link flow. This is how the official Sonos app rates tracks;
/// on cloud-queue firmware it's the only working path (the track URI no longer
/// carries a Pandora v5 trackToken).
public struct SMAPICredentials: Sendable, Codable, Equatable {
    public var authToken: String
    public var privateKey: String
    public var householdId: String
    public var deviceId: String

    public init(authToken: String, privateKey: String, householdId: String, deviceId: String) {
        self.authToken = authToken
        self.privateKey = privateKey
        self.householdId = householdId
        self.deviceId = deviceId
    }
}

/// A pending device link the user must authorize in a browser.
public struct SMAPIDeviceLink: Sendable {
    public let regUrl: String
    public let linkCode: String
    public let showLinkCode: Bool
    public let householdId: String
    public let deviceId: String

    public init(regUrl: String, linkCode: String, showLinkCode: Bool,
                householdId: String, deviceId: String) {
        self.regUrl = regUrl
        self.linkCode = linkCode
        self.showLinkCode = showLinkCode
        self.householdId = householdId
        self.deviceId = deviceId
    }
}

public enum SMAPIError: Error, Sendable, CustomStringConvertible {
    case notLinkedRetry
    case notLinkedFailure
    case fault(String)
    case transport(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .notLinkedRetry: return "Waiting for you to authorize in the browser…"
        case .notLinkedFailure: return "Pandora link was declined or expired"
        case .fault(let s): return "Pandora (Sonos) error: \(s)"
        case .transport(let s): return "Network error: \(s)"
        case .badResponse(let s): return "Unexpected Pandora response: \(s)"
        }
    }
}

/// Pandora rating values from the service's Sonos presentation map.
public enum SMAPIRating: Int, Sendable {
    case thumbsUp = 1
    case thumbsDown = 2
}

public actor PandoraSMAPI {
    private static let namespace = "http://www.sonos.com/Services/1.1"

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: String = "https://sonos.pandora.com/v2.1") {
        self.endpoint = URL(string: endpoint)!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: - Household + device identity

    /// Full SMAPI household id (the dotted form) from any player.
    public static func householdId(ip: String) async -> String? {
        guard let url = URL(string: "http://\(ip):1400/status/zp") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let values = FlatXMLParser.parse(data)
        return values["HouseholdControlID"] ?? values["HHID"]
    }

    /// A stable Sonos-style deviceId (MAC:0) derived from a coordinator UDN
    /// like RINCON_347E5CD222DE01400.
    public static func deviceId(fromUDN udn: String) -> String {
        var hex = udn
        if let r = hex.range(of: "RINCON_") { hex = String(hex[r.upperBound...]) }
        // Drop the trailing "01400" port marker; keep the 12-digit MAC.
        if hex.count >= 12 { hex = String(hex.prefix(12)) }
        var pairs: [String] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[idx..<next]))
            idx = next
        }
        return pairs.joined(separator: "-") + ":0"
    }

    // MARK: - AppLink device-link flow

    public func getAppLink(householdId: String, deviceId: String) async throws -> SMAPIDeviceLink {
        let body = """
        <getAppLink xmlns="\(Self.namespace)">\
        <householdId>\(XMLText.escape(householdId))</householdId>\
        <hardware>SonoGlass</hardware>\
        <osVersion>macOS</osVersion>\
        <sonosAppName>SonoGlass</sonosAppName>\
        <callbackPath></callbackPath>\
        </getAppLink>
        """
        let header = """
        <credentials xmlns="\(Self.namespace)">\
        <deviceId>\(XMLText.escape(deviceId))</deviceId>\
        <deviceProvider>Sonos</deviceProvider>\
        </credentials>
        """
        let values = try await soap(action: "getAppLink", header: header, body: body)
        guard let regUrl = values["regUrl"], let linkCode = values["linkCode"] else {
            throw SMAPIError.badResponse("getAppLink missing deviceLink")
        }
        return SMAPIDeviceLink(
            regUrl: regUrl,
            linkCode: linkCode,
            showLinkCode: (values["showLinkCode"] ?? "false") == "true",
            householdId: householdId,
            deviceId: deviceId
        )
    }

    /// Polls for the token after the user authorizes; throws `.notLinkedRetry`
    /// until they do.
    public func getDeviceAuthToken(link: SMAPIDeviceLink) async throws -> SMAPICredentials {
        let body = """
        <getDeviceAuthToken xmlns="\(Self.namespace)">\
        <householdId>\(XMLText.escape(link.householdId))</householdId>\
        <linkCode>\(XMLText.escape(link.linkCode))</linkCode>\
        <linkDeviceId>\(XMLText.escape(link.deviceId))</linkDeviceId>\
        </getDeviceAuthToken>
        """
        let header = """
        <credentials xmlns="\(Self.namespace)">\
        <deviceId>\(XMLText.escape(link.deviceId))</deviceId>\
        <deviceProvider>Sonos</deviceProvider>\
        </credentials>
        """
        let values = try await soap(action: "getDeviceAuthToken", header: header, body: body)
        guard let authToken = values["authToken"] else {
            throw SMAPIError.badResponse("no authToken in response")
        }
        // Pandora names the refresh field privateKey; accept either spelling.
        let privateKey = values["privateKey"] ?? values["key"] ?? ""
        return SMAPICredentials(authToken: authToken, privateKey: privateKey,
                                householdId: link.householdId, deviceId: link.deviceId)
    }

    // MARK: - Rating

    @discardableResult
    public func rateItem(id: String, rating: SMAPIRating,
                         credentials: SMAPICredentials) async throws -> Bool {
        let header = """
        <credentials xmlns="\(Self.namespace)">\
        <loginToken>\
        <token>\(XMLText.escape(credentials.authToken))</token>\
        <key>\(XMLText.escape(credentials.privateKey))</key>\
        <householdId>\(XMLText.escape(credentials.householdId))</householdId>\
        </loginToken>\
        <deviceId>\(XMLText.escape(credentials.deviceId))</deviceId>\
        <deviceProvider>Sonos</deviceProvider>\
        </credentials>
        """
        let body = """
        <rateItem xmlns="\(Self.namespace)">\
        <id>\(XMLText.escape(id))</id>\
        <rating>\(rating.rawValue)</rating>\
        </rateItem>
        """
        let values = try await soap(action: "rateItem", header: header, body: body)
        return (values["shouldSkip"] ?? "false") == "true"
    }

    /// The SMAPI item id Sonos uses for a track is the percent-decoded segment
    /// of the track URI between the scheme and the media extension.
    public static func itemID(fromTrackURI uri: String) -> String? {
        var rest = uri
        for scheme in ["x-sonos-http:", "x-sonosprog-http:"] {
            if let r = rest.range(of: scheme) { rest = String(rest[r.upperBound...]); break }
        }
        guard rest != uri else { return nil }
        if let q = rest.firstIndex(of: "?") { rest = String(rest[..<q]) }
        for ext in [".mp3", ".mp4", ".flac", ".m4a"] where rest.hasSuffix(ext) {
            rest = String(rest.dropLast(ext.count))
            break
        }
        let decoded = rest.removingPercentEncoding ?? rest
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: - SOAP plumbing

    private func soap(action: String, header: String, body: String) async throws -> [String: String] {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Header>\(header)</s:Header>\
        <s:Body>\(body)</s:Body>\
        </s:Envelope>
        """
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.namespace)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.setValue("Linux UPnP/1.0 Sonos/70.0-00000 (SonoGlass)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(envelope.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SMAPIError.transport(error.localizedDescription)
        }
        let values = FlatXMLParser.parse(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 500 || values["faultcode"] != nil {
            let fault = values["faultcode"] ?? ""
            if fault.contains("NOT_LINKED_RETRY") { throw SMAPIError.notLinkedRetry }
            if fault.contains("NOT_LINKED_FAILURE") { throw SMAPIError.notLinkedFailure }
            let detail = values["faultstring"] ?? values["SonosError"] ?? fault
            smapiLog.error("SMAPI \(action, privacy: .public) fault: \(detail, privacy: .public)")
            throw SMAPIError.fault(detail.isEmpty ? "HTTP \(status)" : detail)
        }
        guard status == 200 else {
            throw SMAPIError.badResponse("HTTP \(status)")
        }
        return values
    }
}
