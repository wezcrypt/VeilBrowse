import Foundation
import Observation

enum LockGrace: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: return String(localized: "Immediately")
        case .oneMinute: return String(localized: "After 1 minute")
        case .fiveMinutes: return String(localized: "After 5 minutes")
        }
    }
}

@MainActor
@Observable
final class SecuritySettings {
    private let defaults: UserDefaults

    var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: "security.appLock") } }
    var lockGrace: LockGrace { didSet { defaults.set(lockGrace.rawValue, forKey: "security.lockGrace") } }
    var privacyCoverEnabled: Bool { didSet { defaults.set(privacyCoverEnabled, forKey: "security.privacyCover") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["security.appLock": true, "security.lockGrace": 0, "security.privacyCover": true])
        appLockEnabled = defaults.bool(forKey: "security.appLock")
        lockGrace = LockGrace(rawValue: defaults.integer(forKey: "security.lockGrace")) ?? .immediately
        privacyCoverEnabled = defaults.bool(forKey: "security.privacyCover")
    }
}
