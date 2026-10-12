import Foundation

/// Parses an HTTP `Retry-After` value (delta-seconds or HTTP-date).
enum RetryAfter {
    static let maximum: TimeInterval = 15 * 60

    static func seconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return min(seconds, maximum)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(max(date.timeIntervalSince(now), 0), maximum)
    }

    static func seconds(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        seconds(response.value(forHTTPHeaderField: "Retry-After"), now: now)
    }
}

/// Shared, thread-safe "the server asked us to slow down" gate. Every request made
/// through one `BackupAPI` (JSON calls and chunk uploads) reports 429/503 here, and
/// the sync engine starts no new server work until the gate opens. Consecutive
/// pressure signals back off exponentially (with jitter) unless the server sent
/// an explicit Retry-After, which is always honoured.
final class ServerPressure: Sendable {
    struct State: Sendable, Equatable {
        var until: Date?
        var level = 0
        var events = 0
        var lastReason: String?
    }

    private let box = LockedBox(State())
    private let backoff = Backoff(base: 2, maximum: 300)

    var state: State { box.value }

    /// Time the gate stays closed, or nil when requests may be sent.
    func blockedUntil(now: Date = Date()) -> Date? {
        box.withValue { state -> Date? in
            guard let until = state.until, until > now else { return nil }
            return until
        }
    }

    @discardableResult
    func record(status: Int, retryAfter: TimeInterval?, reason: String?, now: Date = Date(), jitter: Double = Double.random(in: 0...1)) -> Date {
        box.withValue { state -> Date in
            state.level = min(state.level + 1, 12)
            state.events += 1
            state.lastReason = reason
            let wait = retryAfter.map { max($0, 1) } ?? backoff.delay(forAttempt: state.level, jitter: jitter)
            let until = now.addingTimeInterval(wait)
            let combined = max(state.until ?? until, until)
            state.until = combined
            return combined
        }
    }

    /// A request succeeded: pressure eases one step at a time (no instant reset, so
    /// a single success during a storm does not release every waiting upload).
    func recordSuccess() {
        box.withValue { state in
            if state.level > 0 { state.level -= 1 }
        }
    }

    func reset() {
        box.withValue { $0 = State() }
    }

    static func isPressure(status: Int) -> Bool {
        status == 429 || status == 503
    }
}

/// Additive-increase / multiplicative-decrease limit for parallel chunk uploads.
/// Starts at one upload, adds one after a run of successes, halves on server
/// pressure, never exceeds the ceiling set by `TransferPolicy` (network, battery,
/// thermal state and the user's setting).
struct AdaptiveConcurrency: Sendable, Equatable {
    private(set) var limit: Int
    private(set) var ceiling: Int
    private(set) var streak = 0

    init(start: Int = 1, ceiling: Int) {
        self.ceiling = max(1, ceiling)
        self.limit = min(max(1, start), self.ceiling)
    }

    /// Successes required before adding one more parallel upload.
    var successesToGrow: Int { max(4, limit * 2) }

    mutating func setCeiling(_ value: Int) {
        ceiling = max(1, value)
        limit = min(limit, ceiling)
    }

    mutating func success() {
        streak += 1
        if streak >= successesToGrow, limit < ceiling {
            limit += 1
            streak = 0
        }
    }

    mutating func pressure() {
        limit = max(1, limit / 2)
        streak = 0
    }

    mutating func failure() {
        streak = 0
    }
}

/// Upload speed over two windows: a short one for the live figure and a long one
/// for the average used by the time estimate (so the ETA does not jump around).
struct ThroughputMeter: Sendable {
    private var samples: [(Date, Int64)] = []
    var window: TimeInterval = 10
    var averageWindow: TimeInterval = 120

    mutating func add(_ bytes: Int64, at date: Date = Date()) {
        samples.append((date, bytes))
        trim(now: date)
    }

    mutating func rate(now: Date = Date()) -> Double {
        trim(now: now)
        return Self.rate(samples.filter { now.timeIntervalSince($0.0) <= window }, now: now, minimumSpan: 1)
    }

    mutating func averageRate(now: Date = Date()) -> Double {
        trim(now: now)
        return Self.rate(samples, now: now, minimumSpan: 5)
    }

    private mutating func trim(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.0) > averageWindow }
    }

    private static func rate(_ samples: [(Date, Int64)], now: Date, minimumSpan: TimeInterval) -> Double {
        guard let first = samples.first else { return 0 }
        let bytes = samples.reduce(Int64(0)) { $0 + $1.1 }
        return Double(bytes) / max(now.timeIntervalSince(first.0), minimumSpan)
    }
}

/// Remaining time from remaining *bytes* and the averaged speed. Returns nil while
/// there is not enough data for a meaningful estimate.
enum TransferEstimate {
    static func eta(remainingBytes: Int64, averageBytesPerSecond: Double) -> TimeInterval? {
        guard remainingBytes > 0, averageBytesPerSecond.isFinite, averageBytesPerSecond > 1024 else { return nil }
        let seconds = Double(remainingBytes) / averageBytesPerSecond
        return seconds.isFinite && seconds < 365 * 86400 ? seconds : nil
    }
}
