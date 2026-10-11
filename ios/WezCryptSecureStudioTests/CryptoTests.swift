import CryptoKit
import XCTest
@testable import WezCryptSecureStudio

/// Vectors shared with backend/tests/test_wzce.py (Python reference implementation).
final class CryptoTests: XCTestCase {
    let recoveryKey = SymmetricKey(data: Data(0..<32))
    let objectID = Data(16..<32)
    let plaintext = Data("WezCrypt Secure Studio client-side vector".utf8)
    let vectorHex = "575a434501010000000000100000000000000029101112131415161718191a1b1c1d1e1fc8c9cacbcccdcecf000102030405060708090a0b57c5d436dd4ee119fe73bdcb4f7c5417639fa135914ec9866da659fb7d21363c76e5eef770938d777d5c87e0dc5f12fc0da186e890ca14e6520b14d3f74ffba9c6432a38ad8bd64dd6d93a482f81cce7494f755ecdf7728626d2117dc0562a775f75fbc24781be8337fd3de780bbf9e60f318892a52fe6612d81f7e1d7eb6ab7d53c8a7f777b564bb7"

    func testKeyDerivationMatchesPython() {
        let keys = VaultKeys(recoveryKey: recoveryKey)
        XCTAssertEqual(keys.fingerprint, "7d942a851b495aa926bdff435a205077ecc8866a5094996d51d6250132d58adc")
        XCTAssertEqual(keys.contentTag(kind: "photo", resources: [(role: "photo", sha256: String(repeating: "00", count: 32))]),
                       "7f28a76aafc407ac52b5a868c67d77914ec0b9133822a40ff1e1879dedf319c8")
        XCTAssertEqual(RecoveryKit.format(recoveryKey), "000G4-0R40M-30E20-9185G-R38E1-W8124-GK2GA-HC5RR-34D1P-70X3R-FP638")
    }

    func testEncryptionMatchesPythonByteForByte() throws {
        let keys = VaultKeys(recoveryKey: recoveryKey)
        let encryptor = try WZCE.Encryptor(kek: keys.fileWrap, objectID: objectID, plaintextSize: UInt64(plaintext.count), segmentSize: 16,
                                           dataKey: SymmetricKey(data: Data(100..<132)), noncePrefix: Data(200..<208), keyNonce: Data(0..<12))
        var blob = encryptor.headerData
        for index in 0..<encryptor.header.segmentCount {
            let start = index * 16
            blob.append(try encryptor.encryptSegment(index: index, plaintext: plaintext.subdata(in: start..<min(start + 16, plaintext.count))))
        }
        XCTAssertEqual(blob.hexString, vectorHex)
        XCTAssertEqual(try WZCE.decrypt(try XCTUnwrap(Data(hexString: vectorHex)), kek: keys.fileWrap, expectedObjectID: objectID), plaintext)
    }

    func testRoundTripSizes() throws {
        let kek = SymmetricKey(size: .bits256)
        for size in [0, 1, 15, 16, 17, 4095, 70_001] {
            let id = WZCE.randomBytes(16)
            let data = WZCE.randomBytes(size)
            let blob = try WZCE.encrypt(data, kek: kek, objectID: id, segmentSize: 4096)
            XCTAssertEqual(UInt64(blob.count), WZCE.ciphertextSize(plaintextSize: UInt64(size), segmentSize: 4096))
            XCTAssertEqual(try WZCE.decrypt(blob, kek: kek, expectedObjectID: id), data)
        }
    }

    func testUniqueNoncesAndKeysPerEncryption() throws {
        let kek = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        let data = Data(repeating: 7, count: 1000)
        let a = try WZCE.encrypt(data, kek: kek, objectID: id)
        let b = try WZCE.encrypt(data, kek: kek, objectID: id)
        XCTAssertNotEqual(a, b, "same plaintext must never produce the same ciphertext")
        XCTAssertNotEqual(a.subdata(in: 36..<56), b.subdata(in: 36..<56))
    }

    func testCorruptedSegmentDetected() throws {
        let kek = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        var blob = try WZCE.encrypt(WZCE.randomBytes(10_000), kek: kek, objectID: id, segmentSize: 1024)
        blob[WZCE.headerSize + 2_000] ^= 0x01
        XCTAssertThrowsError(try WZCE.decrypt(blob, kek: kek, expectedObjectID: id)) { error in
            XCTAssertEqual(error as? WZCE.Failure, .segmentAuthenticationFailed(1))
        }
    }

    func testReorderedSegmentsDetected() throws {
        let kek = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        let blob = try WZCE.encrypt(WZCE.randomBytes(2048), kek: kek, objectID: id, segmentSize: 1024)
        let segment = 1024 + 16
        let header = blob.prefix(WZCE.headerSize)
        let first = blob.subdata(in: WZCE.headerSize..<(WZCE.headerSize + segment))
        let second = blob.subdata(in: (WZCE.headerSize + segment)..<blob.count)
        XCTAssertThrowsError(try WZCE.decrypt(header + second + first, kek: kek, expectedObjectID: id))
    }

    func testTruncationTrailingDataWrongKeyAndWrongObject() throws {
        let kek = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        let blob = try WZCE.encrypt(WZCE.randomBytes(3000), kek: kek, objectID: id, segmentSize: 1024)
        XCTAssertThrowsError(try WZCE.decrypt(blob.prefix(blob.count - 1), kek: kek, expectedObjectID: id))
        XCTAssertThrowsError(try WZCE.decrypt(blob + Data([0]), kek: kek, expectedObjectID: id))
        XCTAssertThrowsError(try WZCE.decrypt(blob, kek: SymmetricKey(size: .bits256), expectedObjectID: id)) { error in
            XCTAssertEqual(error as? WZCE.Failure, .keyUnwrapFailed)
        }
        XCTAssertThrowsError(try WZCE.decrypt(blob, kek: kek, expectedObjectID: WZCE.randomBytes(16))) { error in
            XCTAssertEqual(error as? WZCE.Failure, .wrongObject)
        }
    }

    func testRecoveryKeyParsingAndTypoDetection() throws {
        let key = RecoveryKit.generateKey()
        let text = RecoveryKit.format(key)
        XCTAssertEqual(text.filter { $0 != "-" }.count, 55)
        let parsed = try RecoveryKit.parse(text.lowercased().replacingOccurrences(of: "-", with: " "))
        XCTAssertEqual(VaultKeys(recoveryKey: parsed).fingerprint, VaultKeys(recoveryKey: key).fingerprint)
        var chars = Array(text)
        chars[0] = chars[0] == "A" ? "B" : "A"
        XCTAssertThrowsError(try RecoveryKit.parse(String(chars)))
        XCTAssertThrowsError(try RecoveryKit.parse("too-short"))
    }

    func testManifestSealOpenAndTag() throws {
        let keys = VaultKeys(recoveryKey: RecoveryKit.generateKey())
        let itemID = WZCE.randomBytes(16)
        var manifest = ItemManifest(kind: .livePhoto, source: "photos", originalFilename: "IMG_0001.HEIC", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    modifiedAt: nil, pixelWidth: 4032, pixelHeight: 3024, duration: nil, isFavorite: true,
                                    resources: [.init(role: .photo, objectId: "aa", filename: "IMG_0001.HEIC", uti: "public.heic", size: 10, sha256: "11"),
                                                .init(role: .pairedVideo, objectId: "bb", filename: "IMG_0001.MOV", uti: "com.apple.quicktime-movie", size: 20, sha256: "22")])
        let sealed = try manifest.sealed(itemID: itemID, keys: keys)
        XCTAssertNil(sealed.range(of: Data("IMG_0001".utf8)), "filenames must not appear in the encrypted manifest")
        XCTAssertEqual(try ItemManifest.open(sealed, itemID: itemID, keys: keys), manifest)
        XCTAssertThrowsError(try ItemManifest.open(sealed, itemID: WZCE.randomBytes(16), keys: keys))
        let json = try XCTUnwrap(String(data: ItemManifest.encoder.encode(manifest), encoding: .utf8))
        XCTAssertTrue(json.contains("\"object_id\":\"aa\""), "manifest JSON must match the Python restore tool")
        let tag = manifest.contentTag(keys: keys)
        manifest.resources.append(.init(role: .thumbnail, objectId: "cc", filename: "t.jpg", uti: nil, size: 1, sha256: "33"))
        XCTAssertEqual(manifest.contentTag(keys: keys), tag, "thumbnails do not affect duplicate detection")
    }

    func testKeyVaultPersistsAndRecoversWithRecoveryKey() throws {
        let service = "tests.keyvault.\(UUID().uuidString)"
        let vault = KeyVault(keychain: KeychainStore(service: service))
        XCTAssertFalse(vault.isConfigured)
        let key = RecoveryKit.generateKey()
        try vault.store(recoveryKey: key)
        let reopened = KeyVault(keychain: KeychainStore(service: service))
        XCTAssertEqual(try reopened.keys().fingerprint, VaultKeys(recoveryKey: key).fingerprint)
        // "New device": a different keychain with the key typed in from paper.
        let other = KeyVault(keychain: KeychainStore(service: service + ".new"))
        try other.store(recoveryKey: try RecoveryKit.parse(RecoveryKit.format(key)))
        let id = WZCE.randomBytes(16)
        let blob = try WZCE.encrypt(Data("photo".utf8), kek: try vault.keys().fileWrap, objectID: id)
        XCTAssertEqual(try WZCE.decrypt(blob, kek: try other.keys().fileWrap, expectedObjectID: id), Data("photo".utf8))
        reopened.erase()
        other.erase()
        XCTAssertFalse(KeyVault(keychain: KeychainStore(service: service)).isConfigured)
    }
}
