import Foundation
import SonosKit
import PandoraKit

/// Command-line smoke test for SonosKit against the real network.
/// Usage: swift run sonoglass-diag [speaker-ip]
@main
struct Diag {
    static func main() async {
        let manualIP = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

        print("== Discovery ==")
        async let ssdp = SSDPDiscovery.search(duration: 3.0)
        async let bonjour = BonjourDiscovery.search(duration: 3.0)
        var ips = await ssdp.union(await bonjour)
        if let manualIP { ips.insert(manualIP) }
        print("Candidates: \(ips.sorted())")
        guard let firstIP = ips.first else {
            print("No speakers found.")
            return
        }

        let soap = SOAPClient()
        do {
            print("\n== Topology (via \(firstIP)) ==")
            let topo = try await soap.call(ip: firstIP, service: .zoneGroupTopology,
                                           action: "GetZoneGroupState")
            let groups = ZoneGroupParser.parse(topo["ZoneGroupState"] ?? "")
            for group in groups {
                print("  \(group.displayName)  coordinator=\(group.coordinatorUDN)")
                for member in group.members {
                    print("    \(member.roomName)  \(member.ip)  \(member.udn)")
                }
            }
            guard let coordinator = groups.first?.coordinator else { return }

            print("\n== Now playing (\(coordinator.roomName)) ==")
            let info = try await soap.call(ip: coordinator.ip, service: .avTransport,
                                           action: "GetTransportInfo", args: [("InstanceID", "0")])
            print("  Transport: \(info["CurrentTransportState"] ?? "?")")
            let pos = try await soap.call(ip: coordinator.ip, service: .avTransport,
                                          action: "GetPositionInfo", args: [("InstanceID", "0")])
            print("  TrackURI: \(pos["TrackURI"] ?? "")")
            if let md = pos["TrackMetaData"], md.hasPrefix("<"), let item = DIDLParser.parse(md).first {
                print("  Track: \(item.title) — \(item.artist) [\(item.album)]")
                print("  Art: \(item.albumArtURI.prefix(80))")
            }
            let media = try await soap.call(ip: coordinator.ip, service: .avTransport,
                                            action: "GetMediaInfo", args: [("InstanceID", "0")])
            let stationURI = media["CurrentURI"] ?? ""
            print("  StationURI: \(stationURI)")
            if let md = media["CurrentURIMetaData"], md.hasPrefix("<"), let item = DIDLParser.parse(md).first {
                print("  Station: \(item.title)")
            }
            if let tokens = PandoraTokens.parse(trackURI: pos["TrackURI"] ?? "") {
                print("  Pandora tokens: track=\(tokens.trackToken.prefix(24))… station=\(tokens.stationToken)")
            }

            print("\n== Services ==")
            let svc = try await soap.call(ip: firstIP, service: .musicServices,
                                          action: "ListAvailableServices")
            let services = ServiceListParser.parse(svc["AvailableServiceDescriptorList"] ?? "")
            if let pandora = services.first(where: { $0.name == "Pandora" }) {
                print("  Pandora sid = \(pandora.id)")
            }
            print("  \(services.count) services known to household")

            print("\n== Favorites (FV:2) ==")
            let browse = try await soap.call(ip: coordinator.ip, service: .contentDirectory,
                                             action: "Browse", args: [
                ("ObjectID", "FV:2"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
                ("StartingIndex", "0"), ("RequestedCount", "100"), ("SortCriteria", ""),
            ])
            let favorites = DIDLParser.parse(browse["Result"] ?? "")
            for fav in favorites.prefix(20) {
                let kind = FavoriteClassifier.classify(res: fav.res)
                print("  [\(kind)] \(fav.title)  (\(fav.description))  res=\(fav.res.prefix(60))")
                if fav.resMD.isEmpty { print("    ⚠️ no resMD") }
            }
            print("  \(favorites.count) favorites total")

            print("\n== Playlists (SQ:) ==")
            let sq = try await soap.call(ip: coordinator.ip, service: .contentDirectory,
                                         action: "Browse", args: [
                ("ObjectID", "SQ:"), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
                ("StartingIndex", "0"), ("RequestedCount", "100"), ("SortCriteria", ""),
            ])
            let playlists = DIDLParser.parse(sq["Result"] ?? "")
            for playlist in playlists {
                print("  \(playlist.title)  res=\(playlist.res)")
            }
            print("  \(playlists.count) playlists total")
        } catch {
            print("Error: \(error)")
        }
    }
}
