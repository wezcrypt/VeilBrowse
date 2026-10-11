import Foundation

/// Owns the session tokens. Tokens live only in the Keychain and in memory, and
/// refreshes are single-flight so concurrent requests never rotate twice.
actor SessionCredentialStore {
    private static let keychainKey = "session.credentials.v1"
    private let keychain: KeychainStore
    private var cached: SessionCredentials?
    private var loaded = false
    private var refreshTask: Task<SessionCredentials, Error>?

    /// Emits `true` when signed in and `false` when the session ends.
    nonisolated let changes: AsyncStream<Bool>
    private let changesContinuation: AsyncStream<Bool>.Continuation

    init(keychain: KeychainStore) {
        self.keychain = keychain
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(8))
        changes = stream
        changesContinuation = continuation
    }

    func current() -> SessionCredentials? {
        if !loaded {
            loaded = true
            do {
                cached = try keychain.codable(SessionCredentials.self, for: Self.keychainKey)
            } catch {
                Log.auth.error("Failed to read session from Keychain: \(error.localizedDescription, privacy: .public)")
                cached = nil
            }
        }
        return cached
    }

    func save(_ credentials: SessionCredentials) throws {
        try keychain.setCodable(credentials, for: Self.keychainKey)
        cached = credentials
        loaded = true
        changesContinuation.yield(true)
    }

    func clear() {
        try? keychain.remove(Self.keychainKey)
        let wasSignedIn = cached != nil
        cached = nil
        loaded = true
        refreshTask?.cancel()
        refreshTask = nil
        if wasSignedIn {
            changesContinuation.yield(false)
        }
    }

    /// Runs `operation` once even if many callers ask for a refresh concurrently.
    func refresh(using operation: @escaping @Sendable (SessionCredentials) async throws -> SessionCredentials) async throws -> SessionCredentials {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let credentials = current() else { throw APIError.notSignedIn }
        let task = Task { try await operation(credentials) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            try save(fresh)
            return fresh
        } catch let error as APIError where error == .sessionRevoked {
            clear()
            throw error
        }
    }
}
