import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit

enum AssetExportError: Error, LocalizedError, Equatable {
    case notFound
    case noResource
    case unavailable
    case iCloudDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return String(localized: "The item no longer exists in your library.")
        case .noResource: return String(localized: "The original file for this item is not available.")
        case .unavailable: return String(localized: "This item could not be read.")
        case .iCloudDownloadFailed(let reason): return String(localized: "Downloading the original from iCloud failed: \(reason)")
        }
    }
}

struct ScannedAsset: Sendable, Hashable {
    let localIdentifier: String
    let kind: MediaKind
    let creationDate: Date?
}

struct ExportedAsset: Sendable {
    let fileURL: URL
    let filename: String
    let mimeType: String
    let kind: MediaKind
    let size: Int64
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let durationMs: Int?
    let isFavorite: Bool
    let isScreenshot: Bool
}

/// Exports the *original* resource of a PHAsset to a temporary file, downloading
/// from iCloud Photos when needed. Nothing is ever modified or deleted in Photos.
struct AssetExporter: Sendable {
    let workDirectory: URL

    func export(localIdentifier: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportedAsset {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw AssetExportError.notFound }
        let resources = PHAssetResource.assetResources(for: asset)
        let kind: MediaKind = asset.mediaType == .video ? .video : .photo
        let preferred: [PHAssetResourceType] = kind == .video
            ? [.video, .fullSizeVideo, .pairedVideo]
            : [.photo, .fullSizePhoto, .alternatePhoto]
        guard let resource = preferred.lazy.compactMap({ type in resources.first(where: { $0.type == type }) }).first else {
            throw AssetExportError.noResource
        }

        let originalName = resource.originalFilename.isEmpty ? "\(UUID().uuidString)" : resource.originalFilename
        let destination = workDirectory.appendingPathComponent(UUID().uuidString + "-" + Self.safeFilename(originalName))
        try await write(resource: resource, to: destination, progress: progress)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let utType = UTType(resource.uniformTypeIdentifier)
        let mime = utType?.preferredMIMEType ?? Self.fallbackMIME(for: originalName, kind: kind)
        return ExportedAsset(
            fileURL: destination,
            filename: originalName,
            mimeType: mime,
            kind: kind,
            size: size,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationMs: kind == .video ? Int((asset.duration * 1000).rounded()) : nil,
            isFavorite: asset.isFavorite,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    private func write(resource: PHAssetResource, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let handle = try FileHandle(forWritingTo: destination)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if let progress {
            options.progressHandler = { value in progress(value) }
        }
        let requestID = LockedBox<PHAssetResourceDataRequestID?>(nil)
        let writeError = LockedBox<Error?>(nil)
        let fileHandle = UncheckedSendable(handle)
        defer { try? handle.close() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                    guard writeError.value == nil else { return }
                    do {
                        try fileHandle.value.write(contentsOf: chunk)
                    } catch {
                        writeError.value = error
                        if let id = requestID.value { PHAssetResourceManager.default().cancelDataRequest(id) }
                    }
                } completionHandler: { error in
                    if let failure = writeError.value {
                        continuation.resume(throwing: failure)
                    } else if let error {
                        let nsError = error as NSError
                        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: AssetExportError.iCloudDownloadFailed(error.localizedDescription))
                        }
                    } else {
                        continuation.resume()
                    }
                }
                requestID.value = id
            }
        } onCancel: {
            if let id = requestID.value { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
        try handle.synchronize()
    }

    /// JPEG thumbnail (max 512 px) generated from the exported original:
    /// ImageIO for photos (HEIC/JPEG/PNG/RAW), AVAssetImageGenerator for videos.
    static func makeThumbnail(for exported: ExportedAsset) async -> Data? {
        switch exported.kind {
        case .photo:
            return ImageDownsampler.jpegThumbnail(fileURL: exported.fileURL, maxPixelSize: 512)
        case .video:
            return await VideoThumbnailGenerator.jpegThumbnail(for: AVURLAsset(url: exported.fileURL), maxPixelSize: 512)
        }
    }

    static func safeFilename(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
        return String(cleaned.prefix(120))
    }

    static func fallbackMIME(for filename: String, kind: MediaKind) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType { return mime }
        switch ext {
        case "heic", "heif": return "image/heic"
        case "dng": return "image/x-adobe-dng"
        case "mov": return "video/quicktime"
        case "mp4", "m4v": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

/// Enumerates the device library for full and incremental scans.
struct LibraryScanner: Sendable {
    enum ScanError: Error { case tokenExpired }

    struct IncrementalChanges: Sendable {
        let inserted: [ScannedAsset]
        let deleted: [String]
        let token: Data?
    }

    func fullScan(kinds: [MediaKind], batchSize: Int = 2_000, onBatch: @Sendable ([ScannedAsset]) async throws -> Void) async throws -> Int {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = Self.predicate(for: kinds)
        let result = PHAsset.fetchAssets(with: options)
        let total = result.count
        var index = 0
        while index < total {
            try Task.checkCancellation()
            let upper = min(index + batchSize, total)
            let batch: [ScannedAsset] = autoreleasepool {
                result.objects(at: IndexSet(integersIn: index..<upper)).map(Self.scanned)
            }
            try await onBatch(batch)
            index = upper
        }
        return total
    }

    func currentToken() -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    func changes(since tokenData: Data, kinds: [MediaKind]) throws -> IncrementalChanges {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: tokenData) else {
            throw ScanError.tokenExpired
        }
        var inserted = Set<String>()
        var deleted = Set<String>()
        var detailsFailed = false
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            changes.enumerateChanges { change, stop in
                do {
                    let details = try change.changeDetails(for: .asset)
                    inserted.formUnion(details.insertedLocalIdentifiers)
                    deleted.formUnion(details.deletedLocalIdentifiers)
                } catch {
                    detailsFailed = true
                    stop.pointee = true
                }
            }
        } catch {
            throw ScanError.tokenExpired
        }
        if detailsFailed { throw ScanError.tokenExpired }
        inserted.subtract(deleted)
        var scanned: [ScannedAsset] = []
        if !inserted.isEmpty {
            let options = PHFetchOptions()
            options.predicate = Self.predicate(for: kinds)
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(inserted), options: options)
            scanned.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in scanned.append(Self.scanned(asset)) }
        }
        return IncrementalChanges(inserted: scanned, deleted: Array(deleted), token: currentToken())
    }

    private static func scanned(_ asset: PHAsset) -> ScannedAsset {
        ScannedAsset(localIdentifier: asset.localIdentifier, kind: asset.mediaType == .video ? .video : .photo, creationDate: asset.creationDate)
    }

    private static func predicate(for kinds: [MediaKind]) -> NSPredicate {
        let types = kinds.map { $0 == .video ? PHAssetMediaType.video.rawValue : PHAssetMediaType.image.rawValue }
        guard !types.isEmpty else { return NSPredicate(value: false) }
        return NSPredicate(format: "mediaType IN %@", types)
    }
}
