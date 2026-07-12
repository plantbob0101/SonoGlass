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
