import CryptoKit
import Foundation
import Security

/// The device identity key. On hardware it lives in the Secure Enclave and can
/// never be exported; the Keychain only stores an opaque, device-bound handle.
/// The server stores the public key at pairing time and requires a signature
/// from it for every session refresh.
final class DeviceKeyManager: Sendable {
    enum Kind: String, Codable, Sendable {
        case secureEnclave
        case software
    }

    private struct StoredKey: Codable {
        let kind: Kind
        let data: Data
    }

    private static let keychainKey = "device.signing.key.v1"
    private let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    var kind: Kind? {
        (try? keychain.codable(StoredKey.self, for: Self.keychainKey))?.kind
    }

    /// DER SubjectPublicKeyInfo of the device key, creating the key if needed.
    func publicKeyDER() throws -> Data {
        let stored = try loadOrCreate()
        switch stored.kind {
        case .secureEnclave:
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.data).publicKey.derRepresentation
        case .software:
            return try P256.Signing.PrivateKey(rawRepresentation: stored.data).publicKey.derRepresentation
        }
    }

    /// ECDSA P-256 / SHA-256 signature in DER form.
    func sign(_ message: Data) throws -> Data {
        guard let stored = try keychain.codable(StoredKey.self, for: Self.keychainKey) else {
            throw APIError.notSignedIn
        }
        switch stored.kind {
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.data)
            return try key.signature(for: message).derRepresentation
        case .software:
            let key = try P256.Signing.PrivateKey(rawRepresentation: stored.data)
            return try key.signature(for: message).derRepresentation
        }
    }

    /// Generates a fresh identity (used for every new pairing).
    @discardableResult
    func rotate() throws -> Data {
        try keychain.remove(Self.keychainKey)
        return try publicKeyDER()
    }

    func reset() {
        try? keychain.remove(Self.keychainKey)
    }

    private func loadOrCreate() throws -> StoredKey {
        if let stored = try keychain.codable(StoredKey.self, for: Self.keychainKey) {
            return stored
        }
        let stored: StoredKey
        if SecureEnclave.isAvailable {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                .privateKeyUsage,
                &error
            ) else {
                throw error?.takeRetainedValue() ?? KeychainError(status: errSecParam)
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            stored = StoredKey(kind: .secureEnclave, data: key.dataRepresentation)
            Log.crypto.info("Created Secure Enclave device key")
        } else {
            // Simulator / devices without a Secure Enclave: software key kept in the Keychain.
            stored = StoredKey(kind: .software, data: P256.Signing.PrivateKey().rawRepresentation)
            Log.crypto.notice("Secure Enclave unavailable; created software device key")
        }
        try keychain.setCodable(stored, for: Self.keychainKey)
        return stored
    }
}
