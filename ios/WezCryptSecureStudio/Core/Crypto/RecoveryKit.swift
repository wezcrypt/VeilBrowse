import CryptoKit
import Foundation

/// Building blocks for the planned client-side encryption mode (see SECURITY.md).
///
/// * A random 256-bit **vault key** would wrap per-file data keys (WZC2 key id
///   `WZC2.clientKeyID`), so the server only ever stores ciphertext.
/// * A random 256-bit **recovery key** is shown once to the user as 55 Crockford
///   Base32 characters (with a 16-bit checksum) and wraps the vault key. The
///   wrapped blob can be stored on the server; without the recovery key it is useless.
/// * New devices obtain the vault key either from the recovery key or from an
///   already-paired device; losing every device *and* the recovery key means the
///   data is unrecoverable by design.
enum RecoveryKit {
    enum Failure: Error, Equatable, LocalizedError {
        case invalidFormat
        case checksumMismatch
        case unwrapFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "The recovery key format is invalid."
            case .checksumMismatch: return "The recovery key contains a typo."
            case .unwrapFailed: return "The recovery key does not match this vault."
            }
        }
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let wrapInfo = Data("wzc-recovery-wrap-v1".utf8)

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

    static func wrap(vaultKey: SymmetricKey, recoveryKey: SymmetricKey) throws -> Data {
        let wrappingKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: recoveryKey, info: wrapInfo, outputByteCount: 32)
        let sealed = try AES.GCM.seal(vaultKey.withUnsafeBytes { Data($0) }, using: wrappingKey, authenticating: wrapInfo)
        guard let combined = sealed.combined else { throw Failure.unwrapFailed }
        return combined
    }

    static func unwrap(_ blob: Data, recoveryKey: SymmetricKey) throws -> SymmetricKey {
        let wrappingKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: recoveryKey, info: wrapInfo, outputByteCount: 32)
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            return SymmetricKey(data: try AES.GCM.open(box, using: wrappingKey, authenticating: wrapInfo))
        } catch {
            throw Failure.unwrapFailed
        }
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
