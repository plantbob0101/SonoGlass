import Foundation
import CryptoSwift

public enum PandoraCrypto {
    public static let encryptKey = "6#26FRL$ZWD"
    public static let decryptKey = "R=U!LH$O2B#"

    public static func encrypt(_ plaintext: String, key: String = encryptKey) throws -> String {
        let blowfish = try Blowfish(key: Array(key.utf8), blockMode: ECB(), padding: .zeroPadding)
        let encrypted = try blowfish.encrypt(Array(plaintext.utf8))
        return hexEncode(encrypted)
    }

    public static func decrypt(_ hex: String, key: String = decryptKey) throws -> [UInt8] {
        let bytes = try hexDecode(hex)
        let blowfish = try Blowfish(key: Array(key.utf8), blockMode: ECB(), padding: .zeroPadding)
        return try blowfish.decrypt(bytes)
    }

    /// Decrypted syncTime layout: 4 junk bytes, then 10 ASCII digits.
    public static func decodeSyncTime(_ decrypted: [UInt8]) -> Int? {
        guard decrypted.count >= 14 else { return nil }
        let digits = decrypted[4..<14]
        let str = String(decoding: digits, as: UTF8.self)
        return Int(str)
    }

    public static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDecode(_ hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else { throw PandoraError.badResponse("odd-length hex") }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw PandoraError.badResponse("invalid hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public enum PandoraError: Error, Sendable, CustomStringConvertible {
    case notConfigured
    case api(code: Int, message: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .notConfigured: return "Add your Pandora account in Settings"
        case .api(let code, let message): return "Pandora: \(message) (\(code))"
        case .badResponse(let detail): return "Pandora: unexpected response (\(detail))"
        }
    }
}
