import OSLog

/// Structured logging. Rules enforced by convention and code review:
/// * Never interpolate tokens, keys, signatures, pairing codes or poll secrets.
/// * Asset identifiers and filenames are logged with `privacy: .private`.
enum Log {
    private static let subsystem = "com.wezcrypt.securestudio"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let photos = Logger(subsystem: subsystem, category: "photos")
    static let crypto = Logger(subsystem: subsystem, category: "crypto")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let storage = Logger(subsystem: subsystem, category: "storage")
}
