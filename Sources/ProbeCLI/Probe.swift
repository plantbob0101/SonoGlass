import Foundation
import SonosKit
import PandoraKit

/// Empirical probe: which Pandora feedback API accepts the ids in modern
/// Sonos cloud-queue track URIs (VC1::ST::ST:<station>::TR:<track>::…)?
/// Usage: pandora-probe <coordinator-ip> [up|down]
/// Reads Pandora credentials from the SonoGlass Keychain item (macOS will
/// ask permission). Tries candidate calls in order, stops at first success.
@main
struct Probe {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            print("usage: pandora-probe <coordinator-ip> [up|down]")
            return
        }
        let ip = CommandLine.arguments[1]
        let positive = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] != "down" : true

        guard let creds = PandoraKeychain.load() else {
            print("FAIL: no credentials in Keychain (or access denied)")
            return
        }
        print("Credentials loaded for \(creds.username)")

        // 1. Current track from the speaker
        let soap = SOAPClient()
        guard let pos = try? await soap.call(ip: ip, service: .avTransport, action: "GetPositionInfo",
                                             args: [("InstanceID", "0")]),
              let trackURI = pos["TrackURI"], !trackURI.isEmpty else {
            print("FAIL: no track playing on \(ip)")
            return
        }
        print("TrackURI: \(trackURI)")
        var title = ""
        if let md = pos["TrackMetaData"], md.hasPrefix("<"), let item = DIDLParser.parse(md).first {
            title = item.title
            print("Track: \(item.title) — \(item.artist)")
        }

        // Parse VC1 segments from the raw URI: ...ST%3a<station>%3a%3aTR%3a<track>%3a%3a...
        let decoded = trackURI.replacingOccurrences(of: "%3a", with: ":")
            .replacingOccurrences(of: "%3A", with: ":")
        var stationNum = "", trackNum = ""
        for segment in decoded.components(separatedBy: "::") {
            if segment.hasPrefix("ST:"), segment.count > 3 {
                stationNum = String(segment.dropFirst(3))
            } else if segment.hasPrefix("TR:") {
                trackNum = String(segment.dropFirst(3))
            }
        }
        guard !stationNum.isEmpty, !trackNum.isEmpty else {
            print("FAIL: could not parse ST/TR from URI")
            return
        }
        print("stationNum=\(stationNum) trackNum=\(trackNum) isPositive=\(positive)\n")

        // 2. v5 tuner API
        let tuner = PandoraClient()
        await tuner.setCredentials(username: creds.username, password: creds.password)
        var stationToken = stationNum
        do {
            let stations = try await tuner.stationList()
            print("v5 login OK, \(stations.count) stations")
            if let match = stations.first(where: { $0.stationId.contains(stationNum) || stationNum.contains($0.stationId) }) {
                stationToken = match.stationToken
                print("matched station: \(match.stationName) token=\(match.stationToken)")
            }
        } catch {
            print("v5 login/stationList failed: \(error)")
        }

        for candidate in ["TR:\(trackNum)", trackNum] {
            do {
                try await tuner.addFeedback(stationToken: stationToken, trackToken: candidate, isPositive: positive)
                print("✅ SUCCESS v5 addFeedback trackToken=\(candidate) stationToken=\(stationToken)")
                return
            } catch {
                print("v5 trackToken=\(candidate): \(error)")
            }
        }

        // 3. Web REST + GraphQL APIs
        let web = WebProbe()
        do {
            try await web.login(username: creds.username, password: creds.password)
            print("web login OK")
        } catch {
            print("web login failed: \(error)")
            return
        }

        let restBodies: [[String: Any]] = [
            ["trackToken": "TR:\(trackNum)", "isPositive": positive],
            ["trackToken": trackNum, "isPositive": positive],
            ["pandoraId": "TR:\(trackNum)", "stationId": stationNum, "isPositive": positive],
            ["pandoraId": "TR:\(trackNum)", "isPositive": positive],
        ]
        for body in restBodies {
            let (ok, response) = await web.post(path: "/api/v1/station/addFeedback", body: body)
            let keys = body.keys.sorted().joined(separator: ",")
            if ok {
                print("✅ SUCCESS REST addFeedback body keys [\(keys)]")
                print("response: \(response.prefix(400))")
                return
            }
            print("REST [\(keys)]: \(response.prefix(240))")
        }

        let value = positive ? "UP" : "DOWN"
        let gqlQueries = [
            "mutation { feedback { setFeedback(targetId: \"TR:\(trackNum)\", sourceContextId: \"ST:0:\(stationNum)\", value: \(value), deviceUuid: \"sonoglass\", elapsedTime: 30) { status } } }",
            "mutation { feedback { setFeedback(targetId: \"TR:\(trackNum)\", sourceContextId: \"ST:\(stationNum)\", value: \(value), deviceUuid: \"sonoglass\", elapsedTime: 30) { status } } }",
            "mutation { feedback { setFeedback(targetId: \"TR:\(trackNum)\", value: \(value), deviceUuid: \"sonoglass\", elapsedTime: 30) { status } } }",
        ]
        for (i, query) in gqlQueries.enumerated() {
            let (ok, response) = await web.post(path: "/api/v1/graphql/graphql", body: ["query": query])
            if ok && !response.contains("\"errors\"") {
                print("✅ SUCCESS GraphQL variant \(i + 1)")
                print("query: \(query)")
                print("response: \(response.prefix(400))")
                return
            }
            print("GraphQL variant \(i + 1): \(response.prefix(300))")
        }

        print("\n❌ All candidates failed for '\(title)'. Full responses above.")
    }
}

final class WebProbe: @unchecked Sendable {
    private let session: URLSession
    private var csrfToken = ""
    private var authToken = ""

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        ]
        session = URLSession(configuration: config)
    }

    func login(username: String, password: String) async throws {
        // Prime cookies to obtain csrftoken.
        var prime = URLRequest(url: URL(string: "https://www.pandora.com/")!)
        prime.httpMethod = "HEAD"
        _ = try? await session.data(for: prime)
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: URL(string: "https://www.pandora.com/")!) {
            for cookie in cookies where cookie.name == "csrftoken" {
                csrfToken = cookie.value
            }
        }
        if csrfToken.isEmpty {
            // Some fronts only set the cookie on GET.
            _ = try? await session.data(from: URL(string: "https://www.pandora.com/")!)
            if let cookies = session.configuration.httpCookieStorage?.cookies(for: URL(string: "https://www.pandora.com/")!) {
                for cookie in cookies where cookie.name == "csrftoken" {
                    csrfToken = cookie.value
                }
            }
        }
        guard !csrfToken.isEmpty else {
            throw PandoraError.badResponse("no csrftoken cookie")
        }

        let (ok, response, headers) = await postRaw(path: "/api/v1/auth/login", body: [
            "username": username, "password": password, "keepLoggedIn": true,
        ])
        guard ok, let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PandoraError.badResponse("login failed")
        }
        // Find the auth token wherever this API version put it.
        for key in ["authToken", "webAuthToken", "token"] {
            if let token = json[key] as? String { authToken = token }
        }
        if authToken.isEmpty {
            print("login JSON keys: \(json.keys.sorted().joined(separator: ", "))")
            print("login response headers: \(headers.keys.map { "\($0)" }.sorted().joined(separator: ", "))")
            if let cookies = session.configuration.httpCookieStorage?.cookies(for: URL(string: "https://www.pandora.com/")!) {
                print("cookies: \(cookies.map(\.name).sorted().joined(separator: ", "))")
                for cookie in cookies where cookie.name.lowercased().contains("auth") || cookie.name == "at" {
                    authToken = cookie.value
                    print("using cookie \(cookie.name) as auth token")
                }
            }
        }
        guard !authToken.isEmpty else {
            throw PandoraError.badResponse("no auth token found after login")
        }
    }

    func post(path: String, body: [String: Any]) async -> (Bool, String) {
        let (ok, text, _) = await postRaw(path: path, body: body)
        return (ok, text)
    }

    func postRaw(path: String, body: [String: Any]) async -> (Bool, String, [AnyHashable: Any]) {
        var request = URLRequest(url: URL(string: "https://www.pandora.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "X-CsrfToken")
        if !authToken.isEmpty {
            request.setValue(authToken, forHTTPHeaderField: "X-AuthToken")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            let text = String(decoding: data, as: UTF8.self)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            return (status == 200, status == 200 ? text : "HTTP \(status): \(text)", http?.allHeaderFields ?? [:])
        } catch {
            return (false, "transport error: \(error.localizedDescription)", [:])
        }
    }
}
