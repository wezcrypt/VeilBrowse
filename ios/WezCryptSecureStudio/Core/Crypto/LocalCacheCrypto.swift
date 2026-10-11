import CryptoKit
import Foundation

/// Encrypts on-device caches (thumbnails) with a random key held in the Keychain
/// (`ThisDeviceOnly`). Deleting the key makes every cached file unreadable, which
/// is how "Sign out" and "Clear cache" guarantee nothing decrypted is left behind.
final class LocalCacheCrypto: Sendable {
    private static let keychainKey = "local.cache.key.v1"
    private static let keyID: UInt32 = 1
    private let keychain: KeychainStore
    private let keyBox = LockedBox<SymmetricKey?>(nil)

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    private func key() throws -> SymmetricKey {
        if let cached = keyBox.value { return cached }
        let key = SymmetricKey(data: try keychain.symmetricSecret(for: Self.keychainKey))
        keyBox.value = key
        return key
    }

    func seal(_ data: Data) throws -> Data {
        try WZC2.encrypt(data, kek: key(), keyID: Self.keyID)
    }

    func open(_ blob: Data) throws -> Data {
        let key = try key()
        return try WZC2.decrypt(blob) { $0 == Self.keyID ? key : nil }
    }

    func destroyKey() {
        keyBox.value = nil
        try? keychain.remove(Self.keychainKey)
    }
}
