import Foundation

enum AppConfig {
    static let appName = "WezCrypt Secure Studio"
    static let developerName = "wezcrypt"
    static let developerWebsite = URL(string: "https://wezcrypt.com")!
    static let defaultServerURL = "https://studio.rextv.sbs"
    static let defaultCollection = "iphone-backups"
    static let keychainService = "com.wezcrypt.securestudio"
    static let backgroundSessionIdentifier = "com.wezcrypt.securestudio.transfer"
    static let processingTaskIdentifier = "com.wezcrypt.securestudio.sync"
    static let refreshTaskIdentifier = "com.wezcrypt.securestudio.refresh"
    static let maxAttempts = 8

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Release builds only talk HTTPS. Debug/test builds additionally allow plain
    /// HTTP to the loopback interface so integration tests can run against a
    /// local server on the CI machine.
    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            #if DEBUG
            return ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
            #else
            return false
            #endif
        default:
            return false
        }
    }
}
