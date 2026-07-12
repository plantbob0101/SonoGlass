import Foundation

/// A reference to the currently playing Pandora track, extracted from a raw
/// (still percent-encoded) Sonos track URI. Two generations exist:
///
/// Legacy firmware (pre cloud-queue) embeds real Pandora v5 session tokens:
///   x-sonos-http:{trackToken}%3a%3aST%3a{stationToken}%3a%3aRINCON_...?sid=236&...
///
/// Cloud-queue firmware (2024+) embeds Pandora catalog ids instead:
///   x-sonos-http:VC1%3a%3aST%3a%3aST%3a{stationId}%3a%3aTR%3a{trackId}%3a%3a{n}%3a%3aRINCON_...?sid=236&...
///
/// Legacy tokens feed the v5 tuner API; modern ids feed the listener GraphQL API.
/// Always parse the RAW string — never URL-decode the whole URI first.
public enum PandoraTrackRef: Sendable, Equatable {
    case legacy(trackToken: String, stationToken: String)
    case modern(trackId: String, stationId: String)   // trackId is "TR:n", stationId bare digits

    /// Stable key for the per-track optimistic thumb cache.
    public var cacheKey: String {
        switch self {
        case .legacy(let track, _): return track
        case .modern(let track, _): return track
        }
    }

    public static func parse(trackURI: String) -> PandoraTrackRef? {
        guard trackURI.lowercased().hasPrefix("x-sonos-http:")
                || trackURI.lowercased().hasPrefix("x-sonosprog-http:") else { return nil }

        // Legacy shape first: {token}::ST:{station}::RINCON (percent-encoded).
        let legacyPattern = "^x-sonos(?:prog)?-http:(.+?)%3a%3aST%3a(.+?)%3a%3aRINCON"
        if let regex = try? NSRegularExpression(pattern: legacyPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: trackURI, options: [],
                                        range: NSRange(trackURI.startIndex..., in: trackURI)),
           match.numberOfRanges == 3,
           let trackRange = Range(match.range(at: 1), in: trackURI),
           let stationRange = Range(match.range(at: 2), in: trackURI) {
            let track = String(trackURI[trackRange])
            let station = String(trackURI[stationRange])
            // The cloud-queue shape also matches this regex (track="VC1",
            // station starting "%3aST%3a..."); only accept clean legacy hits.
            if !track.isEmpty, !station.isEmpty, track != "VC1", !station.contains("%3a"),
               !station.contains("%3A") {
                return .legacy(trackToken: track, stationToken: station)
            }
        }

        // Modern cloud-queue shape: split on "::" and pick ST:/TR: segments.
        let decoded = trackURI
            .replacingOccurrences(of: "%3a", with: ":")
            .replacingOccurrences(of: "%3A", with: ":")
        var stationId = "", trackId = ""
        for segment in decoded.components(separatedBy: "::") {
            if segment.hasPrefix("ST:"), segment.count > 3, stationId.isEmpty {
                stationId = String(segment.dropFirst(3))
            } else if segment.hasPrefix("TR:"), segment.count > 3, trackId.isEmpty {
                trackId = segment
            }
        }
        if !stationId.isEmpty, !trackId.isEmpty {
            return .modern(trackId: trackId, stationId: stationId)
        }
        return nil
    }
}

/// Legacy alias kept for the diagnostic CLI and tests.
public struct PandoraTokens: Sendable, Equatable {
    public let trackToken: String
    public let stationToken: String

    public static func parse(trackURI: String) -> PandoraTokens? {
        guard case let .legacy(track, station)? = PandoraTrackRef.parse(trackURI: trackURI) else {
            return nil
        }
        return PandoraTokens(trackToken: track, stationToken: station)
    }
}
