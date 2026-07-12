import Foundation

/// Extracts Pandora feedback tokens from a raw (still percent-encoded) Sonos track URI:
///   x-sonos-http:{trackToken}%3a%3aST%3a{stationToken}%3a%3aRINCON_...?sid=236&...
/// Operates on the RAW string — never URL-decode first.
public struct PandoraTokens: Sendable, Equatable {
    public let trackToken: String
    public let stationToken: String

    public static func parse(trackURI: String) -> PandoraTokens? {
        let pattern = "^x-sonos(?:prog)?-http:(.+?)%3a%3aST%3a(.+?)%3a%3aRINCON"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(trackURI.startIndex..., in: trackURI)
        guard let match = regex.firstMatch(in: trackURI, options: [], range: range),
              match.numberOfRanges == 3,
              let trackRange = Range(match.range(at: 1), in: trackURI),
              let stationRange = Range(match.range(at: 2), in: trackURI) else {
            return nil
        }
        let track = String(trackURI[trackRange])
        let station = String(trackURI[stationRange])
        guard !track.isEmpty, !station.isEmpty else { return nil }
        return PandoraTokens(trackToken: track, stationToken: station)
    }
}
