import Foundation

enum APIError: Error, LocalizedError, Sendable, Equatable {
    case notSignedIn
    case sessionRevoked
    case insecureURL
    case transport(URLError)
    case server(status: Int, code: String, message: String, offset: Int64?)
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "This iPhone is not linked to a vault.")
        case .sessionRevoked:
            return String(localized: "This device was signed out. Link it again from Telegram.")
        case .insecureURL:
            return String(localized: "Only HTTPS connections are allowed.")
        case .transport(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "No internet connection.")
            case .timedOut:
                return String(localized: "The server did not respond in time.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return String(localized: "Secure connection failed. The server certificate is not trusted.")
            default:
                return error.localizedDescription
            }
        case .server(_, _, let message, _):
            return message
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.")
        case .decoding:
            return String(localized: "The server response could not be read.")
        }
    }

    var code: String? {
        if case .server(_, let code, _, _) = self { return code }
        return nil
    }

    var status: Int? {
        if case .server(let status, _, _, _) = self { return status }
        return nil
    }

    /// Whether repeating the same request later may succeed.
    var isRetryable: Bool {
        switch self {
        case .transport(let error):
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
                return false
            default:
                return true
            }
        case .server(let status, let code, _, _):
            if code == "upload_busy" { return true }
            return status == 408 || status == 429 || status >= 500
        case .invalidResponse:
            return true
        case .notSignedIn, .sessionRevoked, .insecureURL, .decoding:
            return false
        }
    }

    static func from(status: Int, data: Data) -> APIError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: String
                let message: String
                let offset: Int64?
            }
            let error: Body
        }
        struct FastAPIDetail: Decodable {
            let detail: DetailValue
            enum DetailValue: Decodable {
                case text(String)
                case other
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(String.self) { self = .text(text) } else { self = .other }
                }
            }
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return .server(status: status, code: envelope.error.code, message: envelope.error.message, offset: envelope.error.offset)
        }
        if let detail = try? JSONDecoder().decode(FastAPIDetail.self, from: data) {
            if case .text(let text) = detail.detail {
                return .server(status: status, code: "http_\(status)", message: text, offset: nil)
            }
            return .server(status: status, code: "validation_error", message: String(localized: "The request was rejected by the server."), offset: nil)
        }
        return .server(status: status, code: "http_\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status), offset: nil)
    }
}
