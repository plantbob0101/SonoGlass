import Foundation
import SonosKit
import PandoraKit

/// SMAPI AppLink probe for Pandora thumbs.
///   pandora-probe link   <coordinator-ip>          — start device link, poll, save token
///   pandora-probe rate   <coordinator-ip> up|down  — rate the current track
///   pandora-probe whoami <coordinator-ip>           — print household/device/track id
@main
struct Probe {
    static let tokenPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sonoglass-smapi.json")

    static func main() async {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: pandora-probe link|rate|whoami <ip> [up|down]")
            return
        }
        let cmd = args[1]
        let ip = args[2]
        let smapi = PandoraSMAPI()

        guard var household = await PandoraSMAPI.householdId(ip: ip) else {
            print("FAIL: no household id from \(ip)")
            return
        }
        if let override = ProcessInfo.processInfo.environment["SONOGLASS_HHID"], !override.isEmpty {
            household = override
        }
        let coordUDN = await coordinatorUDN(ip: ip) ?? "RINCON_000000000000"
        let deviceId = PandoraSMAPI.deviceId(fromUDN: coordUDN)
        print("household=\(household)\ndeviceId=\(deviceId)")

        switch cmd {
        case "whoami":
            if let uri = await currentTrackURI(ip: ip) {
                print("trackURI=\(uri)")
                print("itemID=\(PandoraSMAPI.itemID(fromTrackURI: uri) ?? "nil")")
            } else {
                print("no track playing")
            }

        case "link":
            do {
                let link = try await smapi.getAppLink(householdId: household, deviceId: deviceId)
                print("\n=== AUTHORIZE ===")
                print("Open: \(link.regUrl)")
                if link.showLinkCode { print("Enter code: \(link.linkCode)") }
                print("Polling for authorization (Ctrl-C to stop)…\n")
                let attempts = args.count > 3 ? (Int(args[3]) ?? 60) : 60
                for attempt in 1...attempts {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    do {
                        let creds = try await smapi.getDeviceAuthToken(link: link)
                        let data = try JSONEncoder().encode(creds)
                        try data.write(to: tokenPath)
                        print("✅ LINKED. token saved to \(tokenPath.path)")
                        print("authToken=\(creds.authToken.prefix(16))… key=\(creds.privateKey.prefix(8))…")
                        return
                    } catch SMAPIError.notLinkedRetry {
                        print("  [\(attempt)] not yet authorized…")
                    } catch let error as SMAPIError {
                        if case .transport = error {
                            print("  [\(attempt)] transient: \(error) — retrying")
                            continue
                        }
                        print("❌ \(error)")
                        return
                    } catch {
                        print("❌ \(error)")
                        return
                    }
                }
                print("timed out waiting for authorization")
            } catch {
                print("getAppLink failed: \(error)")
            }

        case "count":
            // Totals thumbs across every station (authoritative per-station store).
            guard let creds = PandoraKeychain.load() else {
                print("FAIL: no Pandora credentials in Keychain")
                return
            }
            let tuner = PandoraClient()
            await tuner.setCredentials(username: creds.username, password: creds.password)
            do {
                let stations = try await tuner.stationList()
                print("scanning \(stations.count) stations…")
                var totalUp = 0, totalDown = 0
                var perStation: [(String, Int, Int)] = []
                for station in stations {
                    let ups = (try? await tuner.stationThumbs(stationToken: station.stationToken, positive: true))?.count ?? 0
                    let downs = (try? await tuner.stationThumbs(stationToken: station.stationToken, positive: false))?.count ?? 0
                    totalUp += ups
                    totalDown += downs
                    if ups + downs > 0 { perStation.append((station.stationName, ups, downs)) }
                }
                print("TOTAL 👍 \(totalUp)   👎 \(totalDown)   (across \(perStation.count) stations with feedback)")
                for (name, ups, downs) in perStation.sorted(by: { $0.1 + $0.2 > $1.1 + $1.2 }).prefix(15) {
                    print(String(format: "  %3d👍 %3d👎  %@", ups, downs, name))
                }
            } catch {
                print("❌ \(error)")
            }

        case "gql":
            // pandora-probe gql <ip> '<query>' — listener GraphQL via stored credentials.
            guard args.count > 3, let creds = PandoraKeychain.load() else {
                print("usage: gql <ip> '<query>' (needs Pandora credentials in Keychain)")
                return
            }
            let web = PandoraClient()
            await web.setCredentials(username: creds.username, password: creds.password)
            do {
                print(try await web.webGraphQLQuery(args[3]))
            } catch {
                print("❌ \(error)")
            }

        case "soap":
            // pandora-probe soap <ip> <action> <innerXML> — raw authenticated SMAPI call.
            guard args.count > 4,
                  let data = try? Data(contentsOf: tokenPath),
                  let creds = try? JSONDecoder().decode(SMAPICredentials.self, from: data) else {
                print("usage: soap <ip> <action> <innerXML> (and run 'link' first)")
                return
            }
            do {
                let response = try await smapi.debugCall(action: args[3], innerXML: args[4],
                                                         credentials: creds)
                print(response)
            } catch {
                print("❌ \(error)")
            }

        case "feedback":
            // Lists the station's recent thumbs straight from Pandora (v5 API)
            // to verify a rating actually landed.
            guard let creds = PandoraKeychain.load() else {
                print("FAIL: no Pandora credentials in Keychain")
                return
            }
            guard let uri = await currentTrackURI(ip: ip) else {
                print("FAIL: nothing playing")
                return
            }
            let decoded = uri.replacingOccurrences(of: "%3a", with: ":")
                .replacingOccurrences(of: "%3A", with: ":")
            var stationNum = ""
            for segment in decoded.components(separatedBy: "::") {
                if segment.hasPrefix("ST:"), segment.count > 3, stationNum.isEmpty {
                    stationNum = String(segment.dropFirst(3))
                }
            }
            let tuner = PandoraClient()
            await tuner.setCredentials(username: creds.username, password: creds.password)
            do {
                let stations = try await tuner.stationList()
                guard let station = stations.first(where: { $0.stationId.contains(stationNum) }) ?? stations.first else {
                    print("no station match for \(stationNum)")
                    return
                }
                if args.count > 3 {
                    // Scan every station for a song title (thumbs on shuffle
                    // land on the origin station).
                    let needle = args[3].lowercased()
                    for candidate in stations {
                        guard let ups = try? await tuner.stationThumbs(
                            stationToken: candidate.stationToken, positive: true) else { continue }
                        let hits = ups.filter { $0.lowercased().contains(needle) }
                        for hit in hits { print("  👍 \(hit)   [station: \(candidate.stationName)]") }
                    }
                    print("scan complete")
                } else {
                    print("Station: \(station.stationName)")
                    let ups = try await tuner.stationThumbs(stationToken: station.stationToken, positive: true)
                    print("Thumbs up (\(ups.count)):")
                    for song in ups.prefix(12) { print("  👍 \(song)") }
                }
            } catch {
                print("❌ \(error)")
            }

        case "import":
            // Copies the token captured by 'link' into the app's Keychain item.
            guard let data = try? Data(contentsOf: tokenPath) else {
                print("FAIL: no saved token at \(tokenPath.path)")
                return
            }
            do {
                try PandoraSMAPIKeychain.save(data)
                print("✅ token imported into Keychain (SonoGlass.PandoraSMAPI)")
            } catch {
                print("❌ keychain save failed: \(error)")
            }

        case "redeem":
            // pandora-probe redeem <ip> <linkCode> <linkDeviceId> — collect the
            // token for an already-authorized link code.
            guard args.count > 4 else { print("usage: redeem <ip> <linkCode> <linkDeviceId>"); return }
            let link = SMAPIDeviceLink(regUrl: "", linkCode: args[3], showLinkCode: false,
                                       householdId: household, deviceId: deviceId,
                                       linkDeviceId: args[4])
            do {
                let creds = try await smapi.getDeviceAuthToken(link: link)
                let data = try JSONEncoder().encode(creds)
                try data.write(to: tokenPath)
                try? PandoraSMAPIKeychain.save(data)
                print("✅ LINKED. token saved to \(tokenPath.path) and Keychain")
                print("authToken=\(creds.authToken.prefix(16))… key=\(creds.privateKey.prefix(8))…")
            } catch {
                print("❌ redeem failed: \(error)")
            }

        case "rate":
            let positive = args.count > 3 ? args[3] != "down" : true
            guard let data = try? Data(contentsOf: tokenPath),
                  let creds = try? JSONDecoder().decode(SMAPICredentials.self, from: data) else {
                print("FAIL: no saved token — run 'link' first")
                return
            }
            guard let uri = await currentTrackURI(ip: ip),
                  let itemID = PandoraSMAPI.itemID(fromTrackURI: uri) else {
                print("FAIL: no current track / item id")
                return
            }
            print("itemID=\(itemID)")
            do {
                let skip = try await smapi.rateItem(id: itemID,
                                                    rating: positive ? .thumbsUp : .thumbsDown,
                                                    credentials: creds)
                print("✅ rateItem OK (isPositive=\(positive), shouldSkip=\(skip))")
            } catch {
                print("❌ rateItem failed: \(error)")
            }

        default:
            print("unknown command \(cmd)")
        }
    }

    static func currentTrackURI(ip: String) async -> String? {
        let soap = SOAPClient()
        guard let pos = try? await soap.call(ip: ip, service: .avTransport,
                                             action: "GetPositionInfo", args: [("InstanceID", "0")]),
              let uri = pos["TrackURI"], !uri.isEmpty else { return nil }
        return uri
    }

    static func coordinatorUDN(ip: String) async -> String? {
        let soap = SOAPClient()
        guard let result = try? await soap.call(ip: ip, service: .zoneGroupTopology,
                                                action: "GetZoneGroupState"),
              let xml = result["ZoneGroupState"] else { return nil }
        let groups = ZoneGroupParser.parse(xml)
        return groups.first(where: { g in g.members.contains { $0.ip == ip } })?.coordinatorUDN
            ?? groups.first?.coordinatorUDN
    }
}
