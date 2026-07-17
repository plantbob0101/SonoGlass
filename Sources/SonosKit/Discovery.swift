import Foundation
import Network
import os

private let discoveryLog = Logger(subsystem: "com.sonoglass", category: "discovery")

// MARK: - SSDP

public enum SSDPDiscovery {
    /// Sends UPnP M-SEARCH for Sonos ZonePlayers and collects responder IPs.
    public static func search(duration: TimeInterval = 3.0) async -> Set<String> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingSearch(duration: duration))
            }
        }
    }

    private static func blockingSearch(duration: TimeInterval) -> Set<String> {
        var found = Set<String>()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            discoveryLog.error("SSDP: socket() failed errno=\(errno)")
            return found
        }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000) // 250 ms recv slices
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")

        let message = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 1\r\n"
            + "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n"
            + "\r\n"
        let payload = Array(message.utf8)

        func sendSearch() {
            payload.withUnsafeBufferPointer { buf in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        let deadline = Date().addingTimeInterval(duration)
        var nextSend = Date()
        var sendsLeft = 3
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if sendsLeft > 0, Date() >= nextSend {
                sendSearch()
                sendsLeft -= 1
                nextSend = Date().addingTimeInterval(0.5)
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            var senderAddress = from.sin_addr
            var senderBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let senderIP: String? = if inet_ntop(AF_INET, &senderAddress, &senderBuffer,
                                                 socklen_t(INET_ADDRSTRLEN)) != nil {
                SonosAddress.privateIPv4(String(decoding: senderBuffer
                    .prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
            } else {
                nil
            }

            // LOCATION must name the private host that actually sent the response.
            var advertisedIP: String?
            for line in text.split(separator: "\r\n") {
                if line.lowercased().hasPrefix("location:") {
                    let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                    advertisedIP = URL(string: value)?.host.flatMap(SonosAddress.privateIPv4)
                }
            }
            guard let senderIP else { continue }
            if let advertisedIP, advertisedIP != senderIP { continue }
            found.insert(senderIP)
        }
        discoveryLog.info("SSDP: found \(found.count) responder(s)")
        return found
    }
}

// MARK: - Bonjour

public enum BonjourDiscovery {
    /// Browses _sonos._tcp. and resolves results to IPv4 addresses.
    public static func search(duration: TimeInterval = 3.0) async -> Set<String> {
        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp.", domain: nil), using: .tcp)
        let collector = IPCollector()

        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                let endpoint = result.endpoint
                let conn = NWConnection(to: endpoint, using: .tcp)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let remote = conn.currentPath?.remoteEndpoint,
                           case let .hostPort(host, _) = remote {
                            var ip = "\(host)"
                            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                            if let ip = SonosAddress.privateIPv4(ip) { collector.insert(ip) }
                        }
                        conn.cancel()
                    case .failed, .cancelled:
                        conn.cancel()
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .utility))
            }
        }
        browser.start(queue: .global(qos: .utility))
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        browser.cancel()
        let ips = collector.snapshot()
        discoveryLog.info("Bonjour: found \(ips.count) device(s)")
        return ips
    }

    private final class IPCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var ips = Set<String>()
        func insert(_ ip: String) {
            lock.lock(); defer { lock.unlock() }
            ips.insert(ip)
        }
        func snapshot() -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            return ips
        }
    }
}

// MARK: - Device description

public struct DeviceDescription: Sendable {
    public let udn: String
    public let friendlyName: String
    public let roomName: String
    public let modelName: String

    public static func fetch(ip: String) async throws -> DeviceDescription {
        guard let ip = SonosAddress.privateIPv4(ip) else {
            throw SonosError(message: "Sonos address must be a private IPv4 address")
        }
        let url = URL(string: "http://\(ip):1400/xml/device_description.xml")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        let values = FlatXMLParser.parse(data)
        var udn = values["UDN"] ?? ""
        if udn.hasPrefix("uuid:") { udn = String(udn.dropFirst(5)) }
        return DeviceDescription(
            udn: udn,
            friendlyName: values["friendlyName"] ?? ip,
            roomName: values["roomName"] ?? ip,
            modelName: values["modelName"] ?? ""
        )
    }
}

// MARK: - Local interface address

public enum LocalIP {
    /// IPv4 address of the interface on the same subnet as `peer`.
    public static func matching(peer: String) -> String? {
        guard let peerAddr = ipv4ToUInt32(peer) else { return nil }
        var best: String?
        var fallback: String?
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return nil }
        defer { freeifaddrs(ifaddrsPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var mask: in_addr?
            if let nm = ifa.pointee.ifa_netmask {
                mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            }
            var str = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = addr
            guard inet_ntop(AF_INET, &a, &str, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ipStr = String(decoding: str.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            if fallback == nil { fallback = ipStr }
            if let mask {
                let m = UInt32(bigEndian: mask.s_addr)
                let local = UInt32(bigEndian: addr.s_addr)
                if (local & m) == (peerAddr & m) {
                    best = ipStr
                    break
                }
            }
        }
        return best ?? fallback
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}
