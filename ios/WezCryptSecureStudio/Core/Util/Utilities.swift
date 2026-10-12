import Foundation

/// Wraps a value that is known to be used safely across concurrency domains
/// (for example AVFoundation loading requests that Apple documents as thread-safe).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Thread-safe mutable box guarded by a lock.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&stored)
    }

    var value: Value {
        get { withValue { $0 } }
        set { withValue { $0 = newValue } }
    }
}

/// Exponential backoff with full jitter.
struct Backoff: Sendable {
    var base: TimeInterval = 2
    var maximum: TimeInterval = 15 * 60

    func delay(forAttempt attempt: Int, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 16)
        let ceiling = min(maximum, base * pow(2, Double(exponent)))
        return max(1, ceiling * (0.5 + 0.5 * jitter))
    }
}

enum Formatters {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Always in gigabytes (two decimals), for totals the user compares over time.
    static func gigabytes(_ count: Int64) -> String {
        let value = Double(max(count, 0)) / 1_000_000_000
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " GB"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "—"
    }

    static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case 48...57: return char - 48
        case 65...70: return char - 55
        case 97...102: return char - 87
        default: return nil
        }
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        Swift.withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byteIndex in 0..<MemoryLayout<T>.size {
            value = value << 8 | T(self[startIndex + offset + byteIndex])
        }
        return value
    }
}

enum AppDirectories {
    /// Application Support/Vault — excluded from backups, protected until first unlock
    /// so background sync can work while the device is locked.
    static func applicationSupport() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try prepared(base.appendingPathComponent("Vault", isDirectory: true))
    }

    static func caches(_ name: String) throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try prepared(base.appendingPathComponent(name, isDirectory: true))
    }

    /// Temporary decrypted/exported data. Wiped on launch and after use.
    static func secureTemp(_ name: String) throws -> URL {
        try prepared(FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true))
    }

    private static func prepared(_ url: URL) throws -> URL {
        var directory = url
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    static func wipe(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func availableDeviceCapacity() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
