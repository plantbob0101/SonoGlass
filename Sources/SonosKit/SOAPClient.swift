import Foundation
import os

public enum SonosUPnPService: Sendable, Equatable {
    case avTransport
    case renderingControl
    case groupRenderingControl
    case zoneGroupTopology
    case musicServices
    case contentDirectory

    public var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        case .musicServices: return "/MusicServices/Control"
        case .contentDirectory: return "/MediaServer/ContentDirectory/Control"
        }
    }

    public var eventPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Event"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Event"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Event"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Event"
        case .musicServices: return "/MusicServices/Event"
        case .contentDirectory: return "/MediaServer/ContentDirectory/Event"
        }
    }

    public var serviceType: String {
        switch self {
        case .avTransport: return "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: return "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .zoneGroupTopology: return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .musicServices: return "urn:schemas-upnp-org:service:MusicServices:1"
        case .contentDirectory: return "urn:schemas-upnp-org:service:ContentDirectory:1"
        }
    }
}

public struct SOAPClient: Sendable {
    static let log = Logger(subsystem: "com.sonoglass", category: "soap")

    private let session: URLSession

    public init(timeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: config)
    }

    /// Performs a UPnP SOAP action and returns the first-level child elements
    /// of the action response, flattened to name → text.
    /// Args are ordered (Name, value) pairs; values are XML-escaped here.
    public func call(ip: String, service: SonosUPnPService, action: String,
                     args: [(String, String)] = []) async throws -> [String: String] {
        let argXML = args.map { "<\($0.0)>\(XMLText.escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(service.serviceType)">\(argXML)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: URL(string: "http://\(ip):1400\(service.controlPath)")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SonosError(message: "\(ip) unreachable: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw SonosError(message: "Bad response from \(ip)")
        }

        let values = FlatXMLParser.parse(data)

        if http.statusCode == 500 {
            let code = values["errorCode"].flatMap(Int.init)
            Self.log.error("UPnP fault \(code ?? -1) for \(action) on \(ip)")
            throw SonosError(code: code, message: "UPnP error \(code.map(String.init) ?? "unknown") (\(action))")
        }
        guard http.statusCode == 200 else {
            throw SonosError(message: "HTTP \(http.statusCode) from \(ip) (\(action))")
        }
        return values
    }
}
