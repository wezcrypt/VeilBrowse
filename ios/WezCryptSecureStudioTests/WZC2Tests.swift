import CryptoKit
import XCTest
@testable import WezCryptSecureStudio

final class WZC2Tests: XCTestCase {
    private let kek = SymmetricKey(data: Data(0..<32))

    /// Produced by backend/tests/test_crypto.py::test_cross_language_vector_is_deterministic.
    private let pythonVectorHex =
        "575a4332010000001000000007000102030405060708090a0b2367b07cad8ca870e12cf9e4c1980a1ef7a3f14388022507441a9bfa9de882317e2f72945c2c0622e54e1aab08c06998c8c9cacbcccdcecf00000000000000250da186e890ca14e6520b14d3f74ffba9bab10b24dd88161e85d316d6688a59a4494f755ecdf7728c24cf1161db0b796840abeb03859240ac793ae72eb130b8db0e37dc8bb2033245a1d0d6603d6fc69dd39fdf389c"
    private let vectorPlaintext = Data("WezCrypt Secure Studio interop vector".utf8)

    func testDecryptsPythonVector() throws {
        let blob = try XCTUnwrap(Data(hexString: pythonVectorHex))
        let plaintext = try WZC2.decrypt(blob) { $0 == 7 ? self.kek : nil }
        XCTAssertEqual(plaintext, vectorPlaintext)
    }

    func testEncryptionMatchesPythonByteForByte() throws {
        let segmentSize = 16
        let encryptor = try WZC2.Encryptor(
            kek: kek,
            keyID: 7,
            plaintextSize: UInt64(vectorPlaintext.count),
            segmentSize: segmentSize,
            dataKey: SymmetricKey(data: Data(100..<132)),
            wrapNonce: Data(0..<12),
            noncePrefix: Data(200..<208)
        )
        var output = encryptor.headerData
        for index in 0..<encryptor.header.segmentCount {
            let start = index * segmentSize
            let end = min(start + segmentSize, vectorPlaintext.count)
            output.append(try encryptor.encryptSegment(index: index, plaintext: vectorPlaintext.subdata(in: start..<end)))
        }
        XCTAssertEqual(output.hexString, pythonVectorHex)
    }

    func testRoundTripSizes() throws {
        for size in [0, 1, 15, 16, 17, 1000, 4096, 70_001] {
            let data = WZC2.randomBytes(size)
            let blob = try WZC2.encrypt(data, kek: kek, keyID: 1, segmentSize: 1024)
            XCTAssertEqual(UInt64(blob.count), try WZC2.Header(parsing: blob).ciphertextSize)
            XCTAssertEqual(try WZC2.decrypt(blob, kek: kek), data, "size \(size)")
        }
    }

    func testHeaderIs89Bytes() throws {
        let blob = try WZC2.encrypt(Data("x".utf8), kek: kek, keyID: 1)
        XCTAssertEqual(try WZC2.Header(parsing: blob).serialized().count, 89)
    }

    func testTamperedCiphertextIsRejected() throws {
        var blob = try WZC2.encrypt(WZC2.randomBytes(3000), kek: kek, keyID: 1, segmentSize: 1024)
        blob[WZC2.headerSize + 10] ^= 0x01
        XCTAssertThrowsError(try WZC2.decrypt(blob, kek: kek))
    }

    func testTruncationIsRejected() throws {
        let blob = try WZC2.encrypt(WZC2.randomBytes(3000), kek: kek, keyID: 1, segmentSize: 1024)
        XCTAssertThrowsError(try WZC2.decrypt(blob.prefix(blob.count - 30), kek: kek))
    }

    func testWrongKeyIsRejected() throws {
        let blob = try WZC2.encrypt(Data("secret".utf8), kek: kek, keyID: 1)
        XCTAssertThrowsError(try WZC2.decrypt(blob, kek: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? WZC2.Failure, .keyUnwrapFailed)
        }
        XCTAssertThrowsError(try WZC2.decrypt(blob) { _ in nil }) { error in
            XCTAssertEqual(error as? WZC2.Failure, .unknownKey(1))
        }
    }

    func testFileEncryptionAndRangeDecryption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("plain.bin")
        let sealed = directory.appendingPathComponent("sealed.wzc2")
        let data = WZC2.randomBytes(50_000)
        try data.write(to: plain)
        try WZC2.encryptFile(at: plain, to: sealed, kek: kek, keyID: 3, segmentSize: 4096)
        XCTAssertEqual(try WZC2.decrypt(Data(contentsOf: sealed), kek: kek), data)
        for range: Range<UInt64> in [0..<1, 4095..<4097, 10_000..<30_000, 49_999..<50_000] {
            let slice = try WZC2.decryptRange(of: sealed, range: range) { _ in self.kek }
            XCTAssertEqual(slice, data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
        }
        XCTAssertThrowsError(try WZC2.decryptRange(of: sealed, range: 49_000..<50_001) { _ in self.kek })
    }
}
