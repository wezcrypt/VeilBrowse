import Foundation

// JSON uses snake_case on the wire; the client converts automatically.
// Timestamps are UNIX epoch seconds.

enum MediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case photo
    case video
}

struct SessionCredentials: Codable, Sendable, Equatable {
    let deviceId: String
    var accessToken: String
    var accessExpiresAt: Date
    var refreshToken: String
    var refreshExpiresAt: Date
}

struct PairStartRequest: Encodable, Sendable {
    let deviceName: String
    let deviceModel: String
    let systemVersion: String
    let publicKey: String
}

struct PairStartResponse: Decodable, Sendable, Equatable {
    let pairingId: String
    let code: String
    let pollSecret: String
    let expiresAt: Date
    let pollInterval: Int
    let botUsername: String?
    let telegramLink: String?
}

struct PairPollRequest: Encodable, Sendable {
    let pairingId: String
    let pollSecret: String
}

struct PairPollResponse: Decodable, Sendable {
    let status: String
    let session: SessionCredentials?
}

struct RefreshRequest: Encodable, Sendable {
    let deviceId: String
    let refreshToken: String
    let timestamp: Int
    let signature: String
}

struct DeviceInfo: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let systemVersion: String
    let createdAt: Date
    let lastSeenAt: Date
    let isCurrent: Bool
}

struct DevicesResponse: Decodable, Sendable {
    let devices: [DeviceInfo]
}

struct AccountInfo: Decodable, Sendable, Equatable {
    struct Encryption: Decodable, Sendable, Equatable {
        let algorithm: String
        let container: String
        let keyManagement: String
        let endToEnd: Bool
    }

    struct Limits: Decodable, Sendable, Equatable {
        let maxFileSize: Int64
        let chunkSize: Int
        let segmentSize: Int
    }

    let telegramUserId: Int64
    let deviceId: String
    let mediaCount: Int
    let photoCount: Int
    let videoCount: Int
    let favoriteCount: Int
    let albumCount: Int
    let totalBytes: Int64
    let storageFormat: String
    let encryption: Encryption
    let limits: Limits
}

struct MediaItem: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var filename: String
    let mimeType: String
    let mediaType: MediaKind
    let sizeBytes: Int64
    let sha256: String
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let takenAt: Date
    let addedAt: Date
    var isFavorite: Bool
    let isScreenshot: Bool
    var hasThumbnail: Bool
    let storageKind: String
    var albumIds: [String]?

    var isVideo: Bool { mediaType == .video }
    var duration: TimeInterval? { durationMs.map { TimeInterval($0) / 1000 } }
}

struct LibraryPage: Decodable, Sendable {
    let items: [MediaItem]
    let nextCursor: String?
}

struct SummaryBucket: Decodable, Sendable, Identifiable, Hashable {
    let key: String
    let count: Int
    let totalBytes: Int64
    let coverMediaId: String?
    let start: Date
    let end: Date
    var id: String { key }
}

struct SummaryPage: Decodable, Sendable {
    let buckets: [SummaryBucket]
    let nextBefore: String?
}

struct Album: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    var name: String
    let itemCount: Int
    let totalBytes: Int64
    let coverMediaId: String?
    let createdAt: Date
    let updatedAt: Date
}

struct SmartAlbumStats: Decodable, Sendable, Hashable {
    let itemCount: Int
    let totalBytes: Int64
    let coverMediaId: String?
}

struct AlbumsResponse: Decodable, Sendable {
    struct Smart: Decodable, Sendable, Hashable {
        let favorites: SmartAlbumStats
        let videos: SmartAlbumStats
        let screenshots: SmartAlbumStats
        let recentlyAdded: SmartAlbumStats
    }

    let albums: [Album]
    let smart: Smart
    let recentlyAddedSince: Date
}

struct CreateUploadRequest: Encodable, Sendable {
    let filename: String
    let mimeType: String
    let mediaType: MediaKind
    let sizeBytes: Int64
    let sha256: String
    let takenAt: Int?
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let isFavorite: Bool
    let isScreenshot: Bool
    let localIdentifier: String?
}

struct CreateUploadResponse: Decodable, Sendable {
    let status: String
    let uploadId: String?
    let offset: Int64?
    let sizeBytes: Int64?
    let chunkSize: Int?
    let segmentSize: Int?
    let expiresAt: Date?
    let media: MediaItem?
}

struct UploadProgressResponse: Decodable, Sendable {
    let uploadId: String
    let offset: Int64
    let sizeBytes: Int64
}

struct CompleteUploadResponse: Decodable, Sendable {
    let media: MediaItem
}

struct SyncCheckResponse: Decodable, Sendable {
    let existing: [String: String]
}

struct NameBody: Encodable, Sendable {
    let name: String
}

struct AlbumCreateBody: Encodable, Sendable {
    let name: String
    let mediaIds: [String]
}

struct MediaIDsBody: Encodable, Sendable {
    let mediaIds: [String]
}

struct BulkFavoriteBody: Encodable, Sendable {
    let mediaIds: [String]
    let isFavorite: Bool
}

struct MediaPatchBody: Encodable, Sendable {
    let filename: String?
    let isFavorite: Bool?
}

struct CountResponse: Decodable, Sendable {
    let updated: Int?
    let deleted: Int?
}
