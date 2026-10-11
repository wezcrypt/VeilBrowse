import CryptoKit
import Foundation
import Security

/// Stores the recovery key on this device.
///
/// On hardware with a Secure Enclave the key is sealed with AES-GCM under a key
/// derived (ECDH + HKDF) from a P-256 key-agreement key that lives inside the
/// Secure Enclave and can never be exported. The Keychain only holds the sealed
/// blob and the enclave key's opaque, device-bound handle, all
/// `AfterFirstUnlockThisDeviceOnly` (never synced or restored elsewhere, and
/// usable by background uploads after the first unlock).
/// Without a Secure Enclave (simulator) the key is kept directly in the Keychain.
final class KeyVault: Sendable {
    private struct Stored: Codable {
        enum Kind: String, Codable { case secureEnclave, keychain }
        let kind: Kind
        let enclaveKey: Data?
        let ephemeralPublicKey: Data?
        let sealed: Data
        let fingerprint: String
    }

    enum Failure: Error, LocalizedError {
        case missing
        case corrupted

        var errorDescription: String? {
            switch self {
            case .missing: return String(localized: "No recovery key is set up on this iPhone.")
            case .corrupted: return String(localized: "The stored recovery key could not be unlocked.")
            }
        }
    }

    private static let account = "vault.recovery-key.v1"
    private static let wrapSalt = Data("WezCrypt-SE-wrap-v1".utf8)
    private let keychain: KeychainStore
    private let cache = LockedBox<(SymmetricKey, VaultKeys)?>(nil)

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    var isConfigured: Bool {
        (try? keychain.data(for: Self.account)) != nil
    }

    var protection: String {
        guard let stored = try? keychain.codable(Stored.self, for: Self.account) else { return "—" }
        return stored.kind == .secureEnclave ? String(localized: "Secure Enclave") : String(localized: "Keychain (this device only)")
    }

    var fingerprint: String? {
        (try? keychain.codable(Stored.self, for: Self.account))?.fingerprint
    }

    func store(recoveryKey: SymmetricKey) throws {
        let raw = recoveryKey.withUnsafeBytes { Data($0) }
        let fingerprint = VaultKeys(recoveryKey: recoveryKey).fingerprint
        let stored: Stored
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw error?.takeRetainedValue() ?? Failure.corrupted
            }
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let wrapKey = try Self.wrappingKey(ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey))
            guard let sealed = try AES.GCM.seal(raw, using: wrapKey).combined else { throw Failure.corrupted }
            stored = Stored(kind: .secureEnclave, enclaveKey: enclaveKey.dataRepresentation,
                            ephemeralPublicKey: ephemeral.publicKey.x963Representation, sealed: sealed, fingerprint: fingerprint)
        } else {
            stored = Stored(kind: .keychain, enclaveKey: nil, ephemeralPublicKey: nil, sealed: raw, fingerprint: fingerprint)
        }
        try keychain.setCodable(stored, for: Self.account)
        cache.value = (recoveryKey, VaultKeys(recoveryKey: recoveryKey))
    }

    func recoveryKey() throws -> SymmetricKey {
        try load().0
    }

    func keys() throws -> VaultKeys {
        try load().1
    }

    private func load() throws -> (SymmetricKey, VaultKeys) {
        if let cached = cache.value { return cached }
        guard let stored = try keychain.codable(Stored.self, for: Self.account) else { throw Failure.missing }
        let raw: Data
        switch stored.kind {
        case .keychain:
            raw = stored.sealed
        case .secureEnclave:
            guard let handle = stored.enclaveKey, let ephemeral = stored.ephemeralPublicKey else { throw Failure.corrupted }
            do {
                let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle)
                let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
                let wrapKey = try Self.wrappingKey(enclaveKey.sharedSecretFromKeyAgreement(with: publicKey))
                raw = try AES.GCM.open(AES.GCM.SealedBox(combined: stored.sealed), using: wrapKey)
            } catch {
                throw Failure.corrupted
            }
        }
        guard raw.count == 32 else { throw Failure.corrupted }
        let key = SymmetricKey(data: raw)
        let result = (key, VaultKeys(recoveryKey: key))
        cache.value = result
        return result
    }

    private static func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrapSalt, sharedInfo: Data(), outputByteCount: 32)
    }

    func erase() {
        cache.value = nil
        try? keychain.remove(Self.account)
    }
}
