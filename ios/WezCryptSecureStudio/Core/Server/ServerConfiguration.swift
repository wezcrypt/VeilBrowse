import Foundation

enum TransferProtocol: String, Codable, Sendable, CaseIterable, Identifiable {
    case https

    var id: String { rawValue }
    var title: String { "HTTPS" }
}

enum AuthMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return String(localized: "Username & Password")
        case .apiKey: return String(localized: "API Key")
        }
    }
}

/// Non-secret connection settings (UserDefaults). Secrets live in `CredentialStore`.
struct ServerConfiguration: Codable, Sendable, Equatable {
    var serverURL: URL
    var transport: TransferProtocol = .https
    var authMethod: AuthMethod
    var username: String
    var collection: String

    static let collectionPattern = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#
    static let usernamePattern = #"^[a-z0-9][a-z0-9_.-]{1,31}$"#

    enum ValidationError: Error, LocalizedError, Equatable {
        case invalidURL
        case insecureURL
        case invalidUsername
        case invalidCollection
        case missingSecret

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "Enter a valid server address, for example https://studio.rextv.sbs")
            case .insecureURL: return String(localized: "The server address must start with https://")
            case .invalidUsername: return String(localized: "Usernames are 2–32 lowercase letters, digits, dot, dash or underscore.")
            case .invalidCollection: return String(localized: "The backup directory may contain letters, digits, dot, dash and underscore (max 64).")
            case .missingSecret: return String(localized: "Enter your password or API key.")
            }
        }
    }

    static func normalizedURL(_ text: String) throws -> URL {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), let scheme = url.scheme, url.host != nil else { throw ValidationError.invalidURL }
        guard scheme.lowercased() == "https" || AppConfig.isAllowed(url) else { throw ValidationError.insecureURL }
        guard url.path.isEmpty || url.path == "/" else { throw ValidationError.invalidURL }
        return url
    }

    func validate(secret: String) throws {
        guard AppConfig.isAllowed(serverURL) else { throw ValidationError.insecureURL }
        if authMethod == .password, username.range(of: Self.usernamePattern, options: .regularExpression) == nil {
            throw ValidationError.invalidUsername
        }
        guard collection.range(of: Self.collectionPattern, options: .regularExpression) != nil, collection != ".", collection != ".." else {
            throw ValidationError.invalidCollection
        }
        guard !secret.isEmpty else { throw ValidationError.missingSecret }
    }

    private static let defaultsKey = "server.configuration.v2"

    static func load(from defaults: UserDefaults = .standard) -> ServerConfiguration? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Keychain-backed secrets. HTTPS credentials (password / API key / session
/// token) are stored separately per kind; nothing secret touches UserDefaults.
final class CredentialStore: Sendable {
    struct Session: Codable, Sendable {
        let token: String
        let expiresAt: Date
    }

    private let keychain: KeychainStore
    private static let passwordKey = "https.password"
    private static let apiKeyKey = "https.api-key"
    private static let sessionKey = "https.session"

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func secret(for method: AuthMethod) -> String? {
        let key = method == .password ? Self.passwordKey : Self.apiKeyKey
        return (try? keychain.data(for: key)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
    }

    func setSecret(_ value: String, for method: AuthMethod) throws {
        try keychain.set(Data(value.utf8), for: method == .password ? Self.passwordKey : Self.apiKeyKey)
        try? keychain.remove(method == .password ? Self.apiKeyKey : Self.passwordKey)
        clearSession()
    }

    var session: Session? {
        try? keychain.codable(Session.self, for: Self.sessionKey)
    }

    func setSession(_ session: Session) {
        try? keychain.setCodable(session, for: Self.sessionKey)
    }

    func clearSession() {
        try? keychain.remove(Self.sessionKey)
    }

    func eraseAll() {
        for key in [Self.passwordKey, Self.apiKeyKey, Self.sessionKey] {
            try? keychain.remove(key)
        }
    }
}
