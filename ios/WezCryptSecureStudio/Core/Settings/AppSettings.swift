import Foundation
import Observation

enum NetworkMode: String, CaseIterable, Identifiable, Sendable {
    case wifiOnly
    case wifiAndCellular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiOnly: return String(localized: "Wi‑Fi Only")
        case .wifiAndCellular: return String(localized: "Wi‑Fi and Cellular")
        }
    }
}

enum LockGrace: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: return String(localized: "Immediately")
        case .oneMinute: return String(localized: "After 1 minute")
        case .fiveMinutes: return String(localized: "After 5 minutes")
        case .fifteenMinutes: return String(localized: "After 15 minutes")
        }
    }
}

/// Immutable snapshot of the sync-related settings handed to the sync engine.
struct SyncPolicy: Sendable, Equatable {
    var networkMode: NetworkMode
    var respectLowDataMode: Bool
    var maxConcurrentUploads: Int
    var includePhotos: Bool
    var includeVideos: Bool

    var mediaKinds: [MediaKind] {
        var kinds: [MediaKind] = []
        if includePhotos { kinds.append(.photo) }
        if includeVideos { kinds.append(.video) }
        return kinds
    }

    static let `default` = SyncPolicy(networkMode: .wifiOnly, respectLowDataMode: true, maxConcurrentUploads: 2, includePhotos: true, includeVideos: true)
}

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var networkMode: NetworkMode { didSet { defaults.set(networkMode.rawValue, forKey: Keys.networkMode) } }
    var respectLowDataMode: Bool { didSet { defaults.set(respectLowDataMode, forKey: Keys.lowData) } }
    var maxConcurrentUploads: Int { didSet { defaults.set(maxConcurrentUploads, forKey: Keys.concurrency) } }
    var includePhotos: Bool { didSet { defaults.set(includePhotos, forKey: Keys.photos) } }
    var includeVideos: Bool { didSet { defaults.set(includeVideos, forKey: Keys.videos) } }
    var autoSyncOnLaunch: Bool { didSet { defaults.set(autoSyncOnLaunch, forKey: Keys.autoSync) } }
    var backgroundSyncEnabled: Bool { didSet { defaults.set(backgroundSyncEnabled, forKey: Keys.background) } }
    var backgroundRequiresPower: Bool { didSet { defaults.set(backgroundRequiresPower, forKey: Keys.power) } }
    var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: Keys.lock) } }
    var lockGrace: LockGrace { didSet { defaults.set(lockGrace.rawValue, forKey: Keys.lockGrace) } }
    var privacyCoverEnabled: Bool { didSet { defaults.set(privacyCoverEnabled, forKey: Keys.privacy) } }
    var gridColumns: Int { didSet { defaults.set(gridColumns, forKey: Keys.columns) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.networkMode: NetworkMode.wifiOnly.rawValue,
            Keys.lowData: true,
            Keys.concurrency: 2,
            Keys.photos: true,
            Keys.videos: true,
            Keys.autoSync: true,
            Keys.background: true,
            Keys.power: false,
            Keys.lock: true,
            Keys.lockGrace: LockGrace.immediately.rawValue,
            Keys.privacy: true,
            Keys.columns: 4,
        ])
        networkMode = NetworkMode(rawValue: defaults.string(forKey: Keys.networkMode) ?? "") ?? .wifiOnly
        respectLowDataMode = defaults.bool(forKey: Keys.lowData)
        maxConcurrentUploads = min(max(defaults.integer(forKey: Keys.concurrency), 1), 4)
        includePhotos = defaults.bool(forKey: Keys.photos)
        includeVideos = defaults.bool(forKey: Keys.videos)
        autoSyncOnLaunch = defaults.bool(forKey: Keys.autoSync)
        backgroundSyncEnabled = defaults.bool(forKey: Keys.background)
        backgroundRequiresPower = defaults.bool(forKey: Keys.power)
        appLockEnabled = defaults.bool(forKey: Keys.lock)
        lockGrace = LockGrace(rawValue: defaults.integer(forKey: Keys.lockGrace)) ?? .immediately
        privacyCoverEnabled = defaults.bool(forKey: Keys.privacy)
        gridColumns = min(max(defaults.integer(forKey: Keys.columns), 3), 6)
    }

    var syncPolicy: SyncPolicy {
        SyncPolicy(
            networkMode: networkMode,
            respectLowDataMode: respectLowDataMode,
            maxConcurrentUploads: maxConcurrentUploads,
            includePhotos: includePhotos,
            includeVideos: includeVideos
        )
    }

    private enum Keys {
        static let networkMode = "sync.networkMode"
        static let lowData = "sync.respectLowData"
        static let concurrency = "sync.maxConcurrent"
        static let photos = "sync.includePhotos"
        static let videos = "sync.includeVideos"
        static let autoSync = "sync.autoOnLaunch"
        static let background = "sync.background"
        static let power = "sync.backgroundRequiresPower"
        static let lock = "security.appLock"
        static let lockGrace = "security.lockGrace"
        static let privacy = "security.privacyCover"
        static let columns = "library.columns"
    }
}
