import CryptoKit
import XCTest
@testable import WezCryptSecureStudio

final class RecoveryKitTests: XCTestCase {
    func testFormatAndParseRoundTrip() throws {
        let key = RecoveryKit.generateKey()
        let text = RecoveryKit.format(key)
        XCTAssertEqual(text.filter { $0 != "-" }.count, 55)
        let parsed = try RecoveryKit.parse(text.lowercased().replacingOccurrences(of: "-", with: " "))
        XCTAssertEqual(parsed.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
    }

    func testTypoIsDetected() throws {
        var characters = Array(RecoveryKit.format(RecoveryKit.generateKey()))
        let index = characters.firstIndex { $0 != "-" }!
        characters[index] = characters[index] == "A" ? "B" : "A"
        XCTAssertThrowsError(try RecoveryKit.parse(String(characters)))
    }

    func testWrapAndUnwrap() throws {
        let vaultKey = SymmetricKey(size: .bits256)
        let recoveryKey = RecoveryKit.generateKey()
        let blob = try RecoveryKit.wrap(vaultKey: vaultKey, recoveryKey: recoveryKey)
        let unwrapped = try RecoveryKit.unwrap(blob, recoveryKey: recoveryKey)
        XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, vaultKey.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try RecoveryKit.unwrap(blob, recoveryKey: RecoveryKit.generateKey()))
    }

    func testBase32RoundTrip() {
        let data = Data((0..<64).map { UInt8($0 * 3 % 256) })
        XCTAssertEqual(RecoveryKit.base32Decode(RecoveryKit.base32Encode(data))?.prefix(data.count), data)
    }
}
