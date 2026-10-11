import CryptoKit
import Foundation

/// The recovery key is the root of all encryption keys (see VaultKeys). It is a
/// random 256-bit value shown to the user once as 55 Crockford-Base32 characters
/// with a 16-bit checksum, grouped in blocks of five. Whoever holds it can decrypt
/// the backups; without it nobody can — including the server operator.
enum RecoveryKit {
    enum Failure: Error, Equatable, LocalizedError {
        case invalidFormat
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "The recovery key format is invalid."
            case .checksumMismatch: return "The recovery key contains a typo."
            }
        }
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func format(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        var payload = raw
        payload.append(FileHasher.sha256(raw).prefix(2))
        let encoded = base32Encode(payload)
        return stride(from: 0, to: encoded.count, by: 5).map { start in
            let begin = encoded.index(encoded.startIndex, offsetBy: start)
            let end = encoded.index(begin, offsetBy: min(5, encoded.count - start))
            return String(encoded[begin..<end])
        }.joined(separator: "-")
    }

    static func parse(_ text: String) throws -> SymmetricKey {
        let normalized = text.uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .filter { $0 != "-" && !$0.isWhitespace }
        guard let payload = base32Decode(normalized), payload.count == 34 else { throw Failure.invalidFormat }
        let raw = payload.prefix(32)
        guard FileHasher.sha256(Data(raw)).prefix(2) == payload.suffix(2) else { throw Failure.checksumMismatch }
        return SymmetricKey(data: raw)
    }

    static func base32Encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return output
    }

    static func base32Decode(_ text: String) -> Data? {
        var lookup: [Character: UInt32] = [:]
        for (index, char) in alphabet.enumerated() { lookup[char] = UInt32(index) }
        var buffer: UInt32 = 0
        var bits = 0
        var output = Data()
        for char in text {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return output
    }
}
