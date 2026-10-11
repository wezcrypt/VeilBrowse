import Foundation
import Photos
import UIKit

/// A backed-up item with its manifest decrypted locally.
struct VaultItem: Sendable, Identifiable, Equatable {
    let remote: RemoteItem
    let manifest: ItemManifest

    var id: String { remote.itemId }
    var kind: ItemKind { manifest.kind }
    var name: String { manifest.originalFilename ?? manifest.primary?.filename ?? remote.itemId }
    var date: Date { manifest.createdAt ?? remote.createdAt }
}

enum RestoreError: Error, LocalizedError, Equatable {
    case integrity(String)
    case photosDenied
    case missingResource

    var errorDescription: String? {
        switch self {
        case .integrity(let name): return String(localized: "\(name) failed the integrity check after decryption.")
        case .photosDenied: return String(localized: "Allow adding to Photos in Settings to restore photos and videos.")
        case .missingResource: return String(localized: "This backup has no restorable original.")
        }
    }
}

/// Downloads encrypted objects, decrypts them on this device, verifies the
/// plaintext SHA-256 recorded in the encrypted manifest, and only then hands the
/// file to Photos or the Files app. Temporary decrypted files are deleted afterwards.
struct RestoreService: Sendable {
    let api: BackupAPI
    let keys: VaultKeys
    let workDirectory: URL

    /// Decrypts every manifest of a page; items that fail to decrypt are reported, not hidden.
    func page(cursor: String?) async throws -> (items: [VaultItem], failures: Int, next: String?) {
        let page = try await api.items(cursor: cursor)
        var items: [VaultItem] = []
        var failures = 0
        for remote in page.items {
            do {
                guard let blob = Data(base64Encoded: remote.manifest), let itemID = Data(hexString: remote.itemId) else { throw WZCE.Failure.malformedHeader }
                items.append(VaultItem(remote: remote, manifest: try ItemManifest.open(blob, itemID: itemID, keys: keys)))
            } catch {
                failures += 1
            }
        }
        return (items, failures, page.nextCursor)
    }

    /// Downloads and decrypts one resource to a file named after the original. Caller deletes it.
    func decrypt(_ resource: ItemManifest.Resource, into directory: URL? = nil) async throws -> URL {
        let folder = try (directory ?? workDirectory).appendingPathComponent(UUID().uuidString, isDirectory: true).createdDirectory()
        let encrypted = try await api.downloadObject(resource.objectId, to: folder)
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let output = folder.appendingPathComponent(Self.safeName(resource.filename))
        guard let objectID = Data(hexString: resource.objectId) else { throw WZCE.Failure.malformedHeader }
        let sha = try WZCE.decryptFile(at: encrypted, to: output, kek: keys.fileWrap, expectedObjectID: objectID)
        guard sha == resource.sha256 else {
            try? FileManager.default.removeItem(at: output)
            throw RestoreError.integrity(resource.filename)
        }
        return output
    }

    func thumbnail(for item: VaultItem) async throws -> UIImage? {
        guard let resource = item.manifest.thumbnail else { return nil }
        let url = try await decrypt(resource)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return ImageDownsampler.downsample(fileURL: url, maxPixelSize: 400)
    }

    /// Recreates the asset in Photos with its original resources (Live Photos keep their paired video).
    func restoreToPhotos(_ item: VaultItem) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw RestoreError.photosDenied }
        let roles: [ResourceRole: PHAssetResourceType] = [.photo: .photo, .alternatePhoto: .alternatePhoto, .pairedVideo: .pairedVideo, .video: .video]
        let restorable = item.manifest.resources.filter { roles[$0.role] != nil }
        guard !restorable.isEmpty else { throw RestoreError.missingResource }
        var files: [(PHAssetResourceType, URL, String)] = []
        defer { files.forEach { try? FileManager.default.removeItem(at: $0.1.deletingLastPathComponent()) } }
        for resource in restorable {
            files.append((roles[resource.role]!, try await decrypt(resource), resource.filename))
        }
        let creationDate = item.manifest.createdAt
        let favorite = item.manifest.isFavorite ?? false
        let entries = files.map { UncheckedSendable($0) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for entry in entries {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = entry.value.2
                options.shouldMoveFile = false
                request.addResource(with: entry.value.0, fileURL: entry.value.1, options: options)
            }
            request.creationDate = creationDate
            request.isFavorite = favorite
        }
    }

    /// Decrypts the item's files for export to the Files app (caller deletes the folder).
    func decryptForExport(_ item: VaultItem) async throws -> [URL] {
        let resources = item.manifest.resources.filter { $0.role != .thumbnail }
        guard !resources.isEmpty else { throw RestoreError.missingResource }
        let folder = try workDirectory.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true).createdDirectory()
        var urls: [URL] = []
        for resource in resources {
            let decrypted = try await decrypt(resource, into: folder)
            let final = folder.appendingPathComponent(Self.safeName(resource.filename))
            if FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.removeItem(at: final) }
            try FileManager.default.moveItem(at: decrypted, to: final)
            try? FileManager.default.removeItem(at: decrypted.deletingLastPathComponent())
            urls.append(final)
        }
        return urls
    }

    static func safeName(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "file"
        let cleaned = last.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(200))
    }
}
