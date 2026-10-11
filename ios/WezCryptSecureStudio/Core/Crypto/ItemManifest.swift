import CryptoKit
import Foundation

enum ItemKind: String, Codable, Sendable, CaseIterable {
    case photo
    case video
    case livePhoto
    case file

    var title: String {
        switch self {
        case .photo: return String(localized: "Photo")
        case .video: return String(localized: "Video")
        case .livePhoto: return String(localized: "Live Photo")
        case .file: return String(localized: "File")
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .livePhoto: return "livephoto"
        case .file: return "doc"
        }
    }
}

/// Roles of the objects that make up an item. Photo roles mirror
/// PHAssetResourceType so items can be recreated exactly (Live Photos, RAW+JPEG).
enum ResourceRole: String, Codable, Sendable {
    case photo
    case alternatePhoto
    case pairedVideo
    case video
    case file
    case thumbnail
}

/// Encrypted per-item metadata. The server only sees it as an opaque WZCE blob
/// (object id = item id), so filenames, dates and sizes stay private.
struct ItemManifest: Codable, Sendable, Equatable {
    struct Resource: Codable, Sendable, Equatable {
        var role: ResourceRole
        var objectId: String
        var filename: String
        var uti: String?
        var size: Int64
        var sha256: String
    }

    var v = 1
    var kind: ItemKind
    var source: String
    var originalFilename: String?
    var createdAt: Date?
    var modifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var isFavorite: Bool?
    var resources: [Resource]

    var primary: Resource? {
        resources.first { [.photo, .video, .file].contains($0.role) } ?? resources.first { $0.role != .thumbnail }
    }

    var thumbnail: Resource? { resources.first { $0.role == .thumbnail } }

    var payloadBytes: Int64 {
        resources.filter { $0.role != .thumbnail }.reduce(0) { $0 + $1.size }
    }

    func contentTag(keys: VaultKeys) -> String {
        keys.contentTag(kind: kind.rawValue, resources: resources.filter { $0.role != .thumbnail }.map { (role: $0.role.rawValue, sha256: $0.sha256) })
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    func sealed(itemID: Data, keys: VaultKeys) throws -> Data {
        try WZCE.encrypt(Self.encoder.encode(self), kek: keys.fileWrap, objectID: itemID, segmentSize: 64 * 1024)
    }

    static func open(_ blob: Data, itemID: Data, keys: VaultKeys) throws -> ItemManifest {
        try decoder.decode(ItemManifest.self, from: WZCE.decrypt(blob, kek: keys.fileWrap, expectedObjectID: itemID))
    }
}
