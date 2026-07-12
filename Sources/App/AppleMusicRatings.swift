import Foundation
import MusicKit
import os

private let amLog = Logger(subsystem: "com.sonoglass", category: "applemusic")

/// Sets/reads the "Favorite" (love) state of Apple Music catalog songs via
/// MusicKit's ratings API. Requires the app to be signed with a provisioning
/// profile whose App ID has the MusicKit service enabled; on unsigned builds
/// authorization fails gracefully and the star button stays hidden/disabled.
actor AppleMusicRatings {

    enum RatingError: Error, CustomStringConvertible {
        case notAuthorized
        case requestFailed(String)

        var description: String {
            switch self {
            case .notAuthorized:
                return "Apple Music access not authorized (System Settings → Privacy → Media & Apple Music)"
            case .requestFailed(let detail):
                return "Apple Music: \(detail)"
            }
        }
    }

    private var authorized = false

    private func ensureAuthorization() async throws {
        if authorized { return }
        switch MusicAuthorization.currentStatus {
        case .authorized:
            authorized = true
        case .notDetermined:
            let status = await MusicAuthorization.request()
            guard status == .authorized else { throw RatingError.notAuthorized }
            authorized = true
        default:
            throw RatingError.notAuthorized
        }
    }

    /// Top Apple Music catalog match for a title + artist (nil when no hit).
    func findSong(title: String, artist: String) async throws -> String? {
        try await ensureAuthorization()
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 5
        let response = try await request.response()
        // Prefer a song whose artist matches; fall back to the top hit.
        let match = response.songs.first {
            $0.artistName.localizedCaseInsensitiveContains(artist)
                || artist.localizedCaseInsensitiveContains($0.artistName)
        } ?? response.songs.first
        return match?.id.rawValue
    }

    /// Current favorite state; nil when the song has no rating.
    func isFavorite(songID: String) async throws -> Bool? {
        try await ensureAuthorization()
        let url = URL(string: "https://api.music.apple.com/v1/me/ratings/songs/\(songID)")!
        let request = MusicDataRequest(urlRequest: URLRequest(url: url))
        do {
            let response = try await request.response()
            // {"data":[{"attributes":{"value":1}}]}
            if let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let data = json["data"] as? [[String: Any]],
               let attributes = data.first?["attributes"] as? [String: Any],
               let value = attributes["value"] as? Int {
                return value == 1
            }
            return nil
        } catch let error as MusicDataRequest.Error where error.status == 404 {
            return nil   // no rating yet
        }
    }

    func setFavorite(songID: String, favorite: Bool) async throws {
        try await ensureAuthorization()
        let url = URL(string: "https://api.music.apple.com/v1/me/ratings/songs/\(songID)")!
        var urlRequest = URLRequest(url: url)
        if favorite {
            urlRequest.httpMethod = "PUT"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = Data(#"{"type":"rating","attributes":{"value":1}}"#.utf8)
        } else {
            urlRequest.httpMethod = "DELETE"
        }
        do {
            _ = try await MusicDataRequest(urlRequest: urlRequest).response()
            amLog.info("Apple Music favorite=\(favorite) ok for song \(songID, privacy: .public)")
        } catch let error as MusicDataRequest.Error {
            amLog.error("Apple Music rating failed: \(String(describing: error), privacy: .public)")
            throw RatingError.requestFailed(error.title)
        }
    }
}
