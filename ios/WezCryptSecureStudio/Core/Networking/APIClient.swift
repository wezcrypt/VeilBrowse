import Foundation

struct Endpoint: Sendable {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType: String? = "application/json"
    var headers: [String: String] = [:]
    var requiresAuth = true
    var timeout: TimeInterval = 60

    static func get(_ path: String, query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query)
    }

    static func json<T: Encodable>(_ method: String, _ path: String, _ body: T, requiresAuth: Bool = true) throws -> Endpoint {
        Endpoint(method: method, path: path, body: try APIClient.makeEncoder().encode(body), requiresAuth: requiresAuth)
    }
}

/// HTTPS-only client for the WezCrypt native API. Adds the bearer token, refreshes
/// it with a Secure Enclave signature when it expires, and retries once on 401.
final class APIClient: Sendable {
    let baseURL: URL
    let credentials: SessionCredentialStore
    private let deviceKeys: DeviceKeyManager
    private let session: URLSession

    init(baseURL: URL, credentials: SessionCredentialStore, deviceKeys: DeviceKeyManager) {
        precondition(baseURL.scheme?.lowercased() == "https", "The API must use HTTPS")
        self.baseURL = baseURL
        self.credentials = credentials
        self.deviceKeys = deviceKeys
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "WezCryptSecureStudio/\(AppConfig.appVersion) iOS"]
        session = URLSession(configuration: configuration)
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
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    // MARK: - Requests

    func url(for path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw APIError.insecureURL }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme == "https" else { throw APIError.insecureURL }
        return url
    }

    func makeRequest(_ endpoint: Endpoint, accessToken: String?) throws -> URLRequest {
        var request = URLRequest(url: try url(for: endpoint.path, query: endpoint.query), timeoutInterval: endpoint.timeout)
        request.httpMethod = endpoint.method
        request.httpBody = endpoint.body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint.body != nil, let contentType = endpoint.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends the request and returns the raw response for any 2xx status.
    func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        var token = endpoint.requiresAuth ? try await validAccessToken() : nil
        var request = try makeRequest(endpoint, accessToken: token)
        var (data, response) = try await perform(request)
        if response.statusCode == 401, endpoint.requiresAuth {
            token = try await forceRefresh().accessToken
            request = try makeRequest(endpoint, accessToken: token)
            (data, response) = try await perform(request)
            if response.statusCode == 401 {
                await credentials.clear()
                throw APIError.sessionRevoked
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, data: data)
        }
        return (data, response)
    }

    func decode<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send(endpoint)
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            Log.network.error("Decoding \(String(describing: T.self), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw APIError.decoding(String(describing: error))
        }
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

    /// Downloads to a temporary file (used for full-resolution photos). The caller owns and deletes the file.
    func download(_ endpoint: Endpoint) async throws -> URL {
        let token = try await validAccessToken()
        var request = try makeRequest(endpoint, accessToken: token)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        do {
            var (fileURL, response) = try await session.download(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                try? FileManager.default.removeItem(at: fileURL)
                let refreshed = try await forceRefresh()
                request = try makeRequest(endpoint, accessToken: refreshed.accessToken)
                (fileURL, response) = try await session.download(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                try? FileManager.default.removeItem(at: fileURL)
                throw APIError.from(status: http.statusCode, data: data)
            }
            let destination = try AppDirectories.secureTemp("Viewer").appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            return destination
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error)
        }
    }

    // MARK: - Tokens

    func validAccessToken() async throws -> String {
        guard let current = await credentials.current() else { throw APIError.notSignedIn }
        if current.accessExpiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        return try await forceRefresh().accessToken
    }

    @discardableResult
    func forceRefresh() async throws -> SessionCredentials {
        try await credentials.refresh { [self] old in
            try await self.performRefresh(old)
        }
    }

    private func performRefresh(_ old: SessionCredentials) async throws -> SessionCredentials {
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = FileHasher.sha256Hex(Data(old.refreshToken.utf8))
        let message = "WZC-REFRESH-V1\n\(old.deviceId)\n\(timestamp)\n\(digest)"
        let signature = try deviceKeys.sign(Data(message.utf8))
        let body = RefreshRequest(deviceId: old.deviceId, refreshToken: old.refreshToken, timestamp: timestamp, signature: signature.base64EncodedString())
        let request = try makeRequest(try .json("POST", "/api/mobile/session/refresh", body, requiresAuth: false), accessToken: nil)
        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200:
            do {
                return try Self.makeDecoder().decode(SessionCredentials.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        case 401:
            let error = APIError.from(status: 401, data: data)
            if error.code == "clock_skew" {
                // Keep the session; the device clock is wrong.
                throw APIError.server(status: 401, code: "clock_skew", message: String(localized: "Your iPhone's date and time are incorrect. Enable Set Automatically in Settings."), offset: nil)
            }
            Log.auth.notice("Refresh rejected: \(error.code ?? "unknown", privacy: .public)")
            throw APIError.sessionRevoked
        default:
            throw APIError.from(status: response.statusCode, data: data)
        }
    }
}
