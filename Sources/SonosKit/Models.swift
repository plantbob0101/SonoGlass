import Foundation

public struct SonosDevice: Sendable, Hashable, Identifiable {
    public var id: String { udn }
    public let udn: String        // RINCON_XXXX...
    public let ip: String
    public let roomName: String
    public let modelName: String

    public init(udn: String, ip: String, roomName: String, modelName: String = "") {
        self.udn = udn
        self.ip = ip
        self.roomName = roomName
        self.modelName = modelName
    }

    public var baseURL: URL { URL(string: "http://\(ip):1400")! }
}

public struct ZoneGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let coordinatorUDN: String
    public let members: [SonosDevice]   // visible members only

    public init(id: String, coordinatorUDN: String, members: [SonosDevice]) {
        self.id = id
        self.coordinatorUDN = coordinatorUDN
        self.members = members
    }

    public var coordinator: SonosDevice? {
        members.first { $0.udn == coordinatorUDN } ?? members.first
    }

    public var displayName: String {
        guard let coord = coordinator else { return "Unknown" }
        let extras = members.count - 1
        return extras > 0 ? "\(coord.roomName) + \(extras)" : coord.roomName
    }
}

public enum TransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"

    public var isPlaying: Bool { self == .playing || self == .transitioning }
}

public struct NowPlayingState: Sendable, Equatable {
    public var transport: TransportState = .stopped
    public var title: String = ""
    public var artist: String = ""
    public var album: String = ""
    public var artURL: URL?
    public var stationName: String = ""
    /// Raw, still-percent-encoded track URI (critical for Pandora token extraction).
    public var trackURI: String = ""
    /// Raw CurrentURI from GetMediaInfo (station/queue URI — used for service detection).
    public var stationURI: String = ""
    public var relTime: String = ""
    public var duration: String = ""

    public init() {}
}

public struct MusicService: Sendable, Hashable {
    public let id: Int
    public let name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// One entry from a ContentDirectory Browse (favorite, playlist, queue item).
public struct DIDLItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtURI: String     // may be relative (/getaa?...)
    public var upnpClass: String
    public var description: String     // r:description, e.g. "Pandora Station"
    public var res: String             // raw playback URI
    public var resMD: String           // r:resMD — authoritative DIDL metadata for playback
    public var isContainer: Bool

    public init(id: String = "", title: String = "", artist: String = "", album: String = "",
                albumArtURI: String = "", upnpClass: String = "", description: String = "",
                res: String = "", resMD: String = "", isContainer: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURI = albumArtURI
        self.upnpClass = upnpClass
        self.description = description
        self.res = res
        self.resMD = resMD
        self.isContainer = isContainer
    }

    /// Absolute art URL, prefixing relative /getaa paths with the given device.
    public func artURL(via deviceIP: String) -> URL? {
        guard !albumArtURI.isEmpty else { return nil }
        if albumArtURI.hasPrefix("http://") || albumArtURI.hasPrefix("https://") {
            return URL(string: albumArtURI)
        }
        let escaped = albumArtURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "/?&=:%"))) ?? albumArtURI
        return URL(string: "http://\(deviceIP):1400\(escaped)")
    }
}

public enum ResKind: Sendable {
    case stream
    case container
    case unknown
}

public enum FavoriteClassifier {
    static let streamSchemes = [
        "x-sonosapi-stream:", "x-sonosapi-radio:", "x-sonosapi-hls:",
        "x-rincon-mp3radio:", "hls-radio:", "aac:",
    ]
    static let containerSchemes = ["x-rincon-cpcontainer:", "file:"]

    public static func classify(res: String) -> ResKind {
        let lower = res.lowercased()
        if streamSchemes.contains(where: { lower.hasPrefix($0) }) { return .stream }
        if containerSchemes.contains(where: { lower.hasPrefix($0) }) { return .container }
        return .unknown
    }
}

public enum SonosURI {
    /// Extracts a query parameter from a raw Sonos URI without URL-decoding it.
    public static func queryParam(_ name: String, in uri: String) -> String? {
        guard let qIndex = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: qIndex)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return String(parts[1])
            }
        }
        return nil
    }
}

public struct SonosError: Error, Sendable, CustomStringConvertible {
    public let code: Int?          // UPnP error code if any
    public let message: String

    public init(code: Int? = nil, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        if let code { return "Sonos error \(code)" }
        return message
    }
}
