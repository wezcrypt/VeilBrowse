import Foundation

enum LowPowerBehavior: String, CaseIterable, Identifiable, Sendable, Codable {
    case pause
    case reduce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: return String(localized: "Pause backups")
        case .reduce: return String(localized: "Upload slowly (1 at a time)")
        }
    }
}

/// User-controlled sync settings (non-secret, UserDefaults).
struct SyncSettings: Sendable, Equatable, Codable {
    var wifiOnly = true
    var allowCellular = false
    var respectLowDataMode = true
    var chargingOnly = false
    var lowPowerBehavior: LowPowerBehavior = .reduce
    var maxConcurrency = 4
    var chunkSizeMB = 16
    var includePhotos = true
    var includeVideos = true
    var backgroundSync = true

    var chunkSize: Int { min(max(chunkSizeMB, 8), 32) * 1024 * 1024 }

    private static let key = "sync.settings.v2"

    static func load(_ defaults: UserDefaults = .standard) -> SyncSettings {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(SyncSettings.self, from: data) else { return SyncSettings() }
        return value
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Device conditions that influence how hard we push uploads.
struct DeviceConditions: Sendable, Equatable {
    var network = NetworkStatus()
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var isCharging = false
    var batteryLevel: Float = 1

    var thermalTitle: String {
        switch thermal {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Warm")
        case .serious: return String(localized: "Hot")
        case .critical: return String(localized: "Critical")
        @unknown default: return String(localized: "Unknown")
        }
    }
}

struct TransferDecision: Sendable, Equatable {
    var concurrency: Int
    var blockReason: String?

    var isBlocked: Bool { concurrency == 0 }
}

/// Pure decision function (unit-tested): how many parallel chunk uploads are
/// allowed right now, or why uploading must wait.
enum TransferPolicy {
    static func decide(settings: SyncSettings, conditions: DeviceConditions) -> TransferDecision {
        let net = conditions.network
        func block(_ reason: String) -> TransferDecision { TransferDecision(concurrency: 0, blockReason: reason) }

        guard net.isConnected else { return block(String(localized: "Waiting for a network connection")) }
        let onCellularOnly = !net.isWiFi && (net.isCellular || net.isExpensive)
        if onCellularOnly && (settings.wifiOnly || !settings.allowCellular) {
            return block(String(localized: "Waiting for Wi‑Fi"))
        }
        if net.isConstrained && settings.respectLowDataMode {
            return block(String(localized: "Paused by Low Data Mode"))
        }
        if settings.chargingOnly && !conditions.isCharging {
            return block(String(localized: "Waiting for the charger"))
        }
        if conditions.thermal == .critical {
            return block(String(localized: "Paused: iPhone is too hot"))
        }
        if conditions.lowPowerMode && settings.lowPowerBehavior == .pause && !conditions.isCharging {
            return block(String(localized: "Paused by Low Power Mode"))
        }

        var limit = min(max(settings.maxConcurrency, 1), 8)
        switch conditions.thermal {
        case .serious: limit = min(limit, 1)
        case .fair: limit = min(limit, 2)
        default: break
        }
        if conditions.lowPowerMode && !conditions.isCharging { limit = 1 }
        if !conditions.isCharging && conditions.batteryLevel >= 0 && conditions.batteryLevel < 0.2 { limit = min(limit, 1) }
        if onCellularOnly { limit = min(limit, 2) }
        return TransferDecision(concurrency: limit, blockReason: nil)
    }
}
