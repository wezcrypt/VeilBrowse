import Foundation

/// Static configuration. The API base URL can be overridden at build time via the
/// `WZC_API_BASE_URL` build setting (written into Info.plist as `WZCAPIBaseURL`),
/// but only HTTPS URLs are accepted.
enum AppConfig {
    static let appName = "WezCrypt Secure Studio"
    static let developerName = "wezcrypt"
    static let developerWebsite = URL(string: "https://wezcrypt.com")!
    static let defaultAPIBaseURL = URL(string: "https://studio.rextv.sbs")!

    static let apiBaseURL: URL = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "WZCAPIBaseURL") as? String,
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
           url.scheme?.lowercased() == "https",
           url.host != nil {
            return url
        }
        return defaultAPIBaseURL
    }()

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.wezcrypt.securestudio"
    static let keychainService = "com.wezcrypt.securestudio"
    static let backgroundUploadSessionIdentifier = "com.wezcrypt.securestudio.upload"
    static let syncProcessingTaskIdentifier = "com.wezcrypt.securestudio.sync"
    static let appRefreshTaskIdentifier = "com.wezcrypt.securestudio.refresh"

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Maximum number of times an asset is retried before it is marked failed.
    static let maxUploadAttempts = 6
}
