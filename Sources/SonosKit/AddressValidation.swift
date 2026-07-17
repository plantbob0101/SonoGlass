import Foundation

/// Canonicalizes Sonos player addresses and keeps control traffic on the LAN.
public enum SonosAddress {
    /// Accepts numeric RFC1918 or IPv4 link-local addresses only.
    public static func privateIPv4(_ input: String) -> String? {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, candidate, &address) == 1 else { return nil }

        let ip = UInt32(bigEndian: address.s_addr)
        let isPrivate = (ip & 0xFF00_0000) == 0x0A00_0000
            || (ip & 0xFFF0_0000) == 0xAC10_0000
            || (ip & 0xFFFF_0000) == 0xC0A8_0000
            || (ip & 0xFFFF_0000) == 0xA9FE_0000
        guard isPrivate else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                      as: UTF8.self)
    }
}
