import Foundation

struct AccountInfo: Decodable, Sendable, Equatable {
    struct Limits: Decodable, Sendable, Equatable {
        let maxObjectSize: Int64
        let maxChunkSize: Int
        let maxChunksPerObject: Int
        let manifestMaxBytes: Int
    }

    let username: String
    let credential: String
    let serverVersion: String
    let storedBytes: Int64
    let pendingBytes: Int64
    let itemCount: Int
    let quotaBytes: Int64?
    let diskFreeBytes: Int64
    let vaultConfigured: Bool
    let limits: Limits
}

struct VaultInfo: Decodable, Sendable {
    let fingerprint: String
    let format: String
}

struct ReceivedChunk: Decodable, Sendable, Equatable {
    let index: Int
    let sha256: String
}

struct UploadSession: Decodable, Sendable {
    let status: String
    let uploadId: String?
    let objectId: String
    let sizeBytes: Int64
    let chunkCount: Int?
    let received: [ReceivedChunk]?
}

struct CompletedObject: Decodable, Sendable {
    let status: String
    let objectId: String
    let sizeBytes: Int64
    let sha256: String
}

struct RemoteItem: Decodable, Sendable, Identifiable, Equatable {
    let itemId: String
    let collection: String
    let contentTag: String
    let kind: ItemKind
    let manifest: String
    let totalBytes: Int64
    let objectIds: [String]
    let createdAt: Date

    var id: String { itemId }
}

struct ItemPage: Decodable, Sendable {
    let items: [RemoteItem]
    let nextCursor: String?
}

/// HTTPS client for the encrypted backup API (`/api/v2`). It only ever sends
/// ciphertext and encrypted manifests. Authentication is either username +
/// password (exchanged for a revocable session token) or a server-issued API key.
final class BackupAPI: Sendable {
    let configuration: ServerConfiguration
    private let credentials: CredentialStore
    private let session: URLSession
    private let loginGate = LoginGate()

    init(configuration: ServerConfiguration, credentials: CredentialStore, session: URLSession? = nil) {
        self.configuration = configuration
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.requestTimeout
            config.timeoutIntervalForResource = 3600
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            config.httpAdditionalHeaders = ["User-Agent": "WezCryptSecureStudio/\(AppConfig.appVersion)"]
            self.session = URLSession(configuration: config)
        }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    // MARK: - Request plumbing

    func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard AppConfig.isAllowed(configuration.serverURL),
              var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
            throw APIError.insecureURL
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.insecureURL }
        return url
    }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String?, body: Data? = nil,
                 contentType: String? = "application/json", timeout: TimeInterval? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: timeout ?? configuration.requestTimeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil, let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error)
        }
    }

    /// Sends an authenticated request; on an expired session it signs in again once.
    func send(_ build: (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var token = try await bearerToken()
        var (data, response) = try await perform(try build(token))
        if response.statusCode == 401, configuration.authMethod == .password {
            credentials.clearSession()
            token = try await bearerToken()
            (data, response) = try await perform(try build(token))
        }
        guard (200..<300).contains(response.statusCode) else { throw APIError.from(status: response.statusCode, data: data) }
        return (data, response)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, as type: T.Type) async throws -> T {
        let payload = try Self.makeEncoder().encode(body)
        let (data, _) = try await send { try request(method, path, token: $0, body: payload) }
        return try decode(T.self, data)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let (data, _) = try await send { try request("GET", path, query: query, token: $0) }
        return try decode(T.self, data)
    }

    // MARK: - Authentication

    func bearerToken() async throws -> String {
        switch configuration.authMethod {
        case .apiKey:
            guard let key = credentials.secret(for: .apiKey), !key.isEmpty else { throw APIError.notConfigured }
            return key
        case .password:
            if let session = credentials.session, session.expiresAt.timeIntervalSinceNow > 120 {
                return session.token
            }
            return try await loginGate.run { try await self.login() }
        }
    }

    @discardableResult
    func login() async throws -> String {
        struct Body: Encodable { let username: String; let password: String; let deviceLabel: String }
        struct Response: Decodable { let token: String; let expiresAt: Date }
        guard let password = credentials.secret(for: .password) else { throw APIError.notConfigured }
        let body = try Self.makeEncoder().encode(Body(username: configuration.username, password: password, deviceLabel: "WezCrypt iOS"))
        let (data, response) = try await perform(try request("POST", "/api/v2/auth/login", token: nil, body: body))
        guard response.statusCode == 200 else { throw APIError.from(status: response.statusCode, data: data) }
        let result = try decode(Response.self, data)
        credentials.setSession(.init(token: result.token, expiresAt: result.expiresAt))
        return result.token
    }

    func logout() async {
        guard configuration.authMethod == .password, let session = credentials.session else { return }
        _ = try? await perform(try request("POST", "/api/v2/auth/logout", token: session.token))
        credentials.clearSession()
    }

    // MARK: - Endpoints

    func health() async throws {
        let (data, response) = try await perform(try request("GET", "/api/v2/health", token: nil, timeout: 20))
        guard response.statusCode == 200 else { throw APIError.from(status: response.statusCode, data: data) }
    }

    func account() async throws -> AccountInfo {
        try await get("/api/v2/me", as: AccountInfo.self)
    }

    /// Returns nil when no vault fingerprint is registered yet.
    func vault() async throws -> VaultInfo? {
        do {
            return try await get("/api/v2/vault", as: VaultInfo.self)
        } catch let error as APIError where error.code == "vault_not_configured" {
            return nil
        }
    }

    func registerVault(fingerprint: String) async throws {
        struct Body: Encodable { let fingerprint: String; let format: String }
        _ = try await json("PUT", "/api/v2/vault", body: Body(fingerprint: fingerprint, format: "WZCE-1"), as: VaultInfo.self)
    }

    func createUpload(objectID: String, sizeBytes: Int64, chunkSize: Int, chunkCount: Int, sha256: String) async throws -> UploadSession {
        struct Body: Encodable {
            let objectId: String; let collection: String; let sizeBytes: Int64; let chunkSize: Int; let chunkCount: Int; let sha256: String
        }
        return try await json("POST", "/api/v2/uploads", body: Body(objectId: objectID, collection: configuration.collection, sizeBytes: sizeBytes,
                                                                  chunkSize: chunkSize, chunkCount: chunkCount, sha256: sha256), as: UploadSession.self)
    }

    func uploadStatus(_ uploadID: String) async throws -> UploadSession {
        try await get("/api/v2/uploads/\(uploadID)", as: UploadSession.self)
    }

    func chunkRequest(uploadID: String, index: Int, sha256: String, token: String) throws -> URLRequest {
        var req = try request("PUT", "/api/v2/uploads/\(uploadID)/chunks/\(index)", token: token, timeout: 300)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(sha256, forHTTPHeaderField: "X-Chunk-SHA256")
        return req
    }

    func completeUpload(_ uploadID: String) async throws -> CompletedObject {
        let (data, _) = try await send { try request("POST", "/api/v2/uploads/\(uploadID)/complete", token: $0, timeout: 900) }
        return try decode(CompletedObject.self, data)
    }

    func cancelUpload(_ uploadID: String) async throws {
        _ = try await send { try request("DELETE", "/api/v2/uploads/\(uploadID)", token: $0) }
    }

    func deleteObject(_ objectID: String) async throws {
        _ = try await send { try request("DELETE", "/api/v2/objects/\(objectID)", token: $0) }
    }

    enum CreateItemResult: Sendable {
        case created
        case duplicate(existingItemID: String)
    }

    func createItem(itemID: String, contentTag: String, kind: ItemKind, manifest: Data, objectIDs: [String]) async throws -> CreateItemResult {
        struct Body: Encodable {
            let itemId: String; let collection: String; let contentTag: String; let kind: String; let manifest: String; let objectIds: [String]
        }
        let body = Body(itemId: itemID, collection: configuration.collection, contentTag: contentTag, kind: kind.rawValue,
                        manifest: manifest.base64EncodedString(), objectIds: objectIDs)
        do {
            _ = try await json("POST", "/api/v2/items", body: body, as: RemoteItem.self)
            return .created
        } catch let error as APIError where error.code == "duplicate" {
            if case .server(_, _, _, _, let existing?) = error { return .duplicate(existingItemID: existing) }
            throw error
        }
    }

    func existingTags(_ tags: [String]) async throws -> [String: String] {
        struct Body: Encodable { let contentTags: [String] }
        struct Response: Decodable { let existing: [String: String] }
        guard !tags.isEmpty else { return [:] }
        return try await json("POST", "/api/v2/items/check", body: Body(contentTags: tags), as: Response.self).existing
    }

    func items(cursor: String?, limit: Int = 200, allCollections: Bool = false) async throws -> ItemPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if !allCollections { query.append(URLQueryItem(name: "collection", value: configuration.collection)) }
        return try await get("/api/v2/items", query: query, as: ItemPage.self)
    }

    func deleteItem(_ itemID: String) async throws {
        _ = try await send { token in
            var req = try request("DELETE", "/api/v2/items/\(itemID)", token: token)
            req.setValue("yes", forHTTPHeaderField: "X-WZC-Confirm-Delete")
            return req
        }
    }

    /// Downloads an encrypted object to a temporary file owned by the caller.
    func downloadObject(_ objectID: String, to directory: URL) async throws -> URL {
        func attempt(_ token: String) async throws -> (URL, HTTPURLResponse) {
            do {
                let (file, response) = try await session.download(for: try request("GET", "/api/v2/objects/\(objectID)", token: token, timeout: 900))
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                return (file, http)
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw APIError.transport(error)
            }
        }
        var (file, response) = try await attempt(try await bearerToken())
        if response.statusCode == 401, configuration.authMethod == .password {
            try? FileManager.default.removeItem(at: file)
            credentials.clearSession()
            (file, response) = try await attempt(try await bearerToken())
        }
        guard (200..<300).contains(response.statusCode) else {
            let data = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            throw APIError.from(status: response.statusCode, data: data)
        }
        let destination = directory.appendingPathComponent(objectID + ".wzce")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}

/// Serialises concurrent logins so parallel requests share one session token.
actor LoginGate {
    private var task: Task<String, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let task { return try await task.value }
        let task = Task { try await operation() }
        self.task = task
        defer { self.task = nil }
        return try await task.value
    }
}
