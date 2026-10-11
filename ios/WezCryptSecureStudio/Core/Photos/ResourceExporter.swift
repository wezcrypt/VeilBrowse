import Photos
import UniformTypeIdentifiers

enum ExportError: Error, LocalizedError, Equatable {
    case assetNotFound
    case noOriginal
    case iCloudFailed(String)

    var errorDescription: String? {
        switch self {
        case .assetNotFound: return String(localized: "The item was deleted from the photo library.")
        case .noOriginal: return String(localized: "The original file is not available.")
        case .iCloudFailed(let reason): return String(localized: "Downloading the original from iCloud failed: \(reason)")
        }
    }
}

struct ExportedResource: Sendable {
    let role: ResourceRole
    let fileURL: URL
    let filename: String
    let uti: String?
    let size: Int64
}

struct ExportedAsset: Sendable {
    let kind: ItemKind
    let resources: [ExportedResource]
    let createdAt: Date?
    let modifiedAt: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double?
    let isFavorite: Bool

    var totalSize: Int64 { resources.reduce(0) { $0 + $1.size } }
    var primary: ExportedResource? { resources.first { $0.role == .photo || $0.role == .video } ?? resources.first }
}

/// Writes the *original* resources of an asset to files without re-encoding:
/// photo (HEIC/JPEG/PNG/RAW/ProRAW DNG), the alternate photo of RAW+JPEG pairs,
/// the paired video of Live Photos, or the original video. Downloads from
/// iCloud Photos when needed. Never modifies or deletes anything in Photos.
struct ResourceExporter: Sendable {
    let directory: URL

    func export(localID: String, storage: StorageGuard, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExportedAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { throw ExportError.assetNotFound }
        let kind = LibraryScanner.kind(of: asset)
        let all = PHAssetResource.assetResources(for: asset)
        var selected: [(ResourceRole, PHAssetResource)] = []
        if asset.mediaType == .video {
            if let video = all.first(where: { $0.type == .video }) ?? all.first(where: { $0.type == .fullSizeVideo }) { selected.append((.video, video)) }
        } else {
            if let photo = all.first(where: { $0.type == .photo }) ?? all.first(where: { $0.type == .fullSizePhoto }) { selected.append((.photo, photo)) }
            if let alternate = all.first(where: { $0.type == .alternatePhoto }) { selected.append((.alternatePhoto, alternate)) }
            if kind == .livePhoto, let paired = all.first(where: { $0.type == .pairedVideo }) ?? all.first(where: { $0.type == .fullSizePairedVideo }) {
                selected.append((.pairedVideo, paired))
            }
        }
        guard !selected.isEmpty else { throw ExportError.noOriginal }

        var exported: [ExportedResource] = []
        do {
            for (index, entry) in selected.enumerated() {
                try storage.ensure(256 * 1024 * 1024)
                let (role, resource) = entry
                let name = resource.originalFilename.isEmpty ? "\(role.rawValue)-\(UUID().uuidString)" : resource.originalFilename
                let url = directory.appendingPathComponent(UUID().uuidString)
                try await write(resource, to: url) { value in
                    progress?((Double(index) + value) / Double(selected.count))
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                exported.append(ExportedResource(role: role, fileURL: url, filename: name, uti: resource.uniformTypeIdentifier, size: size))
            }
        } catch {
            exported.forEach { try? FileManager.default.removeItem(at: $0.fileURL) }
            throw error
        }
        return ExportedAsset(
            kind: kind,
            resources: exported,
            createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.mediaType == .video ? asset.duration : nil,
            isFavorite: asset.isFavorite
        )
    }

    private func write(_ resource: PHAssetResource, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in progress(value) }
        let requestID = LockedBox<PHAssetResourceDataRequestID?>(nil)
        let writeError = LockedBox<Error?>(nil)
        let box = UncheckedSendable(handle)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                    guard writeError.value == nil else { return }
                    do { try box.value.write(contentsOf: chunk) } catch {
                        writeError.value = error
                        if let id = requestID.value { PHAssetResourceManager.default().cancelDataRequest(id) }
                    }
                } completionHandler: { error in
                    if let failure = writeError.value {
                        continuation.resume(throwing: failure)
                    } else if let error {
                        let ns = error as NSError
                        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: ExportError.iCloudFailed(error.localizedDescription))
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
}
