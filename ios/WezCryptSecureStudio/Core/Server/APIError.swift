import Foundation

enum APIError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured
    case insecureURL
    case unauthorized(code: String, message: String)
    case transport(URLError)
    case server(status: Int, code: String, message: String, missing: [Int]?, itemID: String?)
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "The server is not configured.")
        case .insecureURL:
            return String(localized: "Only HTTPS connections are allowed.")
        case .unauthorized(_, let message):
            return message
        case .transport(let error):
            if Self.isTLSFailure(error.code) {
                return String(localized: "Secure connection failed: the server certificate is not trusted. Connection refused.")
            }
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "No network connection.")
            case .timedOut:
                return String(localized: "The server did not respond in time.")
            case .cannotFindHost, .dnsLookupFailed:
                return String(localized: "The server address could not be found.")
            case .cannotConnectToHost:
                return String(localized: "Could not connect to the server.")
            default:
                return error.localizedDescription
            }
        case .server(_, _, let message, _, _):
            return message
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.")
        case .decoding:
            return String(localized: "The server response could not be read.")
        }
    }

    var code: String? {
        switch self {
        case .unauthorized(let code, _): return code
        case .server(_, let code, _, _, _): return code
        default: return nil
        }
    }

    var status: Int? {
        if case .server(let status, _, _, _, _) = self { return status }
        if case .unauthorized = self { return 401 }
        return nil
    }

    static func isTLSFailure(_ code: URLError.Code) -> Bool {
        [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
         .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
         .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection].contains(code)
    }

    var isTLSFailure: Bool {
        if case .transport(let error) = self { return Self.isTLSFailure(error.code) }
        return false
    }

    /// Whether the same request may succeed later without user action.
    var isRetryable: Bool {
        switch self {
        case .transport(let error):
            return !Self.isTLSFailure(error.code)
        case .server(let status, let code, _, _, _):
            if code == "upload_busy" { return true }
            return status == 408 || status == 429 || status >= 500
        case .invalidResponse:
            return true
        default:
            return false
        }
    }

    static func from(status: Int, data: Data) -> APIError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
                let missing: [Int]?
                let itemId: String?
            }
            let error: Body
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if status == 401 {
                return .unauthorized(code: envelope.error.code, message: envelope.error.message)
            }
            return .server(status: status, code: envelope.error.code, message: envelope.error.message,
                           missing: envelope.error.missing, itemID: envelope.error.itemId)
        }
        if status == 401 {
            return .unauthorized(code: "unauthorized", message: String(localized: "Authentication failed."))
        }
        let message = status == 422
            ? String(localized: "The server rejected the request.")
            : HTTPURLResponse.localizedString(forStatusCode: status)
        return .server(status: status, code: "http_\(status)", message: message, missing: nil, itemID: nil)
    }
}
