import CryptoKit
import Foundation

/// Keys derived from the recovery key with HKDF-SHA256 (salt "WezCrypt-Vault-v1").
/// Identical to `VaultKeys` in backend/tools/wzce.py.
///
/// * `fileWrap` wraps each object's random data key (WZCE header).
/// * `dedup` keys the HMAC content tag used for server-side duplicate detection
///   without revealing plaintext hashes to the server.
/// * `fingerprint` is a public value the server stores to stop two devices from
///   writing into one account with different keys. It reveals nothing about the key.
struct VaultKeys: Sendable {
    static let salt = Data("WezCrypt-Vault-v1".utf8)

    let fileWrap: SymmetricKey
    let dedup: SymmetricKey
    let fingerprint: String

    init(recoveryKey: SymmetricKey) {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: recoveryKey, salt: Self.salt, info: Data(label.utf8), outputByteCount: 32)
        }
        fileWrap = derive("wzce/file-wrap")
        dedup = derive("wzce/dedup")
        let fingerprintKey = derive("wzce/fingerprint")
        fingerprint = Data(HMAC<SHA256>.authenticationCode(for: Data("WezCrypt vault fingerprint v1".utf8), using: fingerprintKey)).hexString
    }

    /// `resources`: (role, plaintext SHA-256 hex), thumbnails excluded.
    func contentTag(kind: String, resources: [(role: String, sha256: String)]) -> String {
        let body = resources
            .sorted { ($0.role, $0.sha256) < ($1.role, $1.sha256) }
            .map { "\($0.role):\($0.sha256)" }
            .joined(separator: ",")
        let message = Data("v1|\(kind)|\(body)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: dedup)).hexString
    }
}
