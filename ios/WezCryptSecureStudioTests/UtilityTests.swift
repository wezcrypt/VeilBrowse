import XCTest
@testable import WezCryptSecureStudio

final class UtilityTests: XCTestCase {
    func testSHA256KnownVector() throws {
        XCTAssertEqual(FileHasher.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try data.write(to: url)
        XCTAssertEqual(try FileHasher.sha256Hex(of: url, chunkSize: 65_536), FileHasher.sha256Hex(data))
    }

    func testHexRoundTrip() {
        let data = Data([0x00, 0x7f, 0x80, 0xff])
        XCTAssertEqual(data.hexString, "007f80ff")
        XCTAssertEqual(Data(hexString: "007F80ff"), data)
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
    }

    func testBackoffGrowsAndIsCapped() {
        let backoff = Backoff(base: 2, maximum: 60)
        XCTAssertEqual(backoff.delay(forAttempt: 1, jitter: 1), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 3, jitter: 1), 8)
        XCTAssertEqual(backoff.delay(forAttempt: 20, jitter: 1), 60)
        XCTAssertEqual(backoff.delay(forAttempt: 3, jitter: 0), 4)
    }

    func testNetworkPolicy() {
        let wifi = NetworkStatus(isConnected: true, isWiFi: true, isCellular: false, isExpensive: false, isConstrained: false)
        let cellular = NetworkStatus(isConnected: true, isWiFi: false, isCellular: true, isExpensive: true, isConstrained: false)
        let lowData = NetworkStatus(isConnected: true, isWiFi: true, isCellular: false, isExpensive: false, isConstrained: true)
        let offline = NetworkStatus()
        var policy = SyncPolicy.default
        XCTAssertTrue(wifi.allows(policy))
        XCTAssertFalse(cellular.allows(policy))
        XCTAssertFalse(lowData.allows(policy))
        XCTAssertFalse(offline.allows(policy))
        XCTAssertNotNil(cellular.blockReason(policy))
        policy.networkMode = .wifiAndCellular
        XCTAssertTrue(cellular.allows(policy))
        policy.respectLowDataMode = false
        XCTAssertTrue(lowData.allows(policy))
        XCTAssertNil(wifi.blockReason(policy))
    }

    func testLibraryQueryItems() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let query = LibraryQuery(mediaType: .video, favorite: true, text: "  IMG ", from: from, albumID: "abc", sort: .added)
        let items = Dictionary(uniqueKeysWithValues: query.queryItems(cursor: "c1", limit: 50).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["type"], "video")
        XCTAssertEqual(items["favorite"], "true")
        XCTAssertEqual(items["q"], "IMG")
        XCTAssertEqual(items["from"], "1700000000")
        XCTAssertEqual(items["album_id"], "abc")
        XCTAssertEqual(items["sort"], "added")
        XCTAssertEqual(items["cursor"], "c1")
        XCTAssertEqual(items["limit"], "50")
        XCTAssertNil(items["to"])
    }

    func testThroughputMeter() {
        var meter = ThroughputMeter()
        let start = Date()
        meter.add(1_000_000, at: start)
        meter.add(1_000_000, at: start.addingTimeInterval(1))
        XCTAssertEqual(meter.rate(now: start.addingTimeInterval(2)), 1_000_000, accuracy: 1)
        XCTAssertEqual(meter.rate(now: start.addingTimeInterval(30)), 0)
    }

    func testActiveUploadFraction() {
        var item = ActiveUpload(id: "a", stage: .uploading, totalBytes: 200, sentBytes: 50)
        XCTAssertEqual(item.fraction, 0.25)
        item.stage = .hashing
        XCTAssertEqual(item.fraction, 0)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.duration(65), "1:05")
        XCTAssertEqual(Formatters.duration(3725), "1:02:05")
        XCTAssertEqual(Formatters.dimensions(width: 4032, height: 3024), "4032 × 3024")
        XCTAssertNil(Formatters.dimensions(width: nil, height: 3))
        XCTAssertEqual(Formatters.speed(0), "—")
        XCTAssertEqual(AccountSettingsView.mask(123456789), "•••••6789")
    }
}
