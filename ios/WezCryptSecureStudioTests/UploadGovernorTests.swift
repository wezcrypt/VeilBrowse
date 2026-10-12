import XCTest
@testable import WezCryptSecureStudio

final class UploadGovernorTests: XCTestCase {
    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RetryAfter.seconds("30", now: now), 30)
        XCTAssertEqual(RetryAfter.seconds(" 2 ", now: now), 2)
        XCTAssertEqual(RetryAfter.seconds("999999", now: now), RetryAfter.maximum, "absurd values are capped")
        XCTAssertNil(RetryAfter.seconds(nil, now: now))
        XCTAssertNil(RetryAfter.seconds("soon", now: now))
        XCTAssertNil(RetryAfter.seconds("-5", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: now.addingTimeInterval(90))
        XCTAssertEqual(RetryAfter.seconds(date, now: now) ?? 0, 90, accuracy: 1)
    }

    func testServerPressureHonoursRetryAfterAndBacksOff() {
        let pressure = ServerPressure()
        let now = Date()
        XCTAssertNil(pressure.blockedUntil(now: now))
        let explicit = pressure.record(status: 429, retryAfter: 7, reason: "busy", now: now, jitter: 1)
        XCTAssertEqual(explicit.timeIntervalSince(now), 7, accuracy: 0.01)
        XCTAssertNotNil(pressure.blockedUntil(now: now.addingTimeInterval(6)))
        XCTAssertNil(pressure.blockedUntil(now: now.addingTimeInterval(8)))
        // Without Retry-After: exponential backoff grows with consecutive pressure.
        let later = now.addingTimeInterval(100)
        let first = pressure.record(status: 503, retryAfter: nil, reason: nil, now: later, jitter: 1).timeIntervalSince(later)
        let second = pressure.record(status: 503, retryAfter: nil, reason: nil, now: later.addingTimeInterval(first), jitter: 1).timeIntervalSince(later.addingTimeInterval(first))
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThanOrEqual(second, 300)
        XCTAssertEqual(pressure.state.events, 3)
        // Successes ease the level gradually.
        let level = pressure.state.level
        pressure.recordSuccess()
        XCTAssertEqual(pressure.state.level, level - 1)
        XCTAssertTrue(ServerPressure.isPressure(status: 429))
        XCTAssertTrue(ServerPressure.isPressure(status: 503))
        XCTAssertFalse(ServerPressure.isPressure(status: 500))
    }

    func testAdaptiveConcurrencyStartsAtOneGrowsAndHalves() {
        var adaptive = AdaptiveConcurrency(start: 1, ceiling: 4)
        XCTAssertEqual(adaptive.limit, 1)
        for _ in 0..<4 { adaptive.success() }
        XCTAssertEqual(adaptive.limit, 2)
        for _ in 0..<4 { adaptive.success() }
        XCTAssertEqual(adaptive.limit, 3)
        for _ in 0..<100 { adaptive.success() }
        XCTAssertEqual(adaptive.limit, 4, "never above the ceiling")
        adaptive.pressure()
        XCTAssertEqual(adaptive.limit, 2)
        adaptive.pressure()
        adaptive.pressure()
        XCTAssertEqual(adaptive.limit, 1, "never below one")
        adaptive = AdaptiveConcurrency(start: 3, ceiling: 4)
        adaptive.setCeiling(1)
        XCTAssertEqual(adaptive.limit, 1, "a lower ceiling (Wi-Fi lost, heat, low power) applies immediately")
        adaptive.failure()
        XCTAssertEqual(adaptive.streak, 0)
    }

    func testThroughputAverageAndByteBasedEstimate() {
        var meter = ThroughputMeter()
        let start = Date()
        for second in 0..<60 { meter.add(1_000_000, at: start.addingTimeInterval(TimeInterval(second))) }
        let now = start.addingTimeInterval(60)
        XCTAssertEqual(meter.averageRate(now: now), 1_000_000, accuracy: 20_000)
        XCTAssertEqual(meter.rate(now: now), 1_000_000, accuracy: 120_000)
        XCTAssertEqual(TransferEstimate.eta(remainingBytes: 10_000_000_000, averageBytesPerSecond: 1_000_000) ?? 0, 10_000, accuracy: 1)
        XCTAssertNil(TransferEstimate.eta(remainingBytes: 0, averageBytesPerSecond: 1_000_000))
        XCTAssertNil(TransferEstimate.eta(remainingBytes: 1_000, averageBytesPerSecond: 0))
    }
}
