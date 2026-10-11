import Observation
import Photos
import PhotosUI
import UIKit

/// Photo library authorization and change notifications.
@MainActor
@Observable
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assetCount = 0
    private(set) var changeCounter = 0
    private var observing = false

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var isLimited: Bool { authorization == .limited }

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard hasAccess else { return }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        assetCount = PHAsset.fetchAssets(with: options).count
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }

    func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.refresh()
            self?.changeCounter += 1
        }
    }
}

/// Full and incremental (persistent change token) enumeration of the library.
struct LibraryScanner: Sendable {
    enum ScanError: Error { case tokenExpired }

    struct Changes: Sendable {
        let inserted: [ScannedAsset]
        let deleted: [String]
        let token: Data?
    }

    static func kind(of asset: PHAsset) -> ItemKind {
        if asset.mediaType == .video { return .video }
        return asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
    }

    private static func predicate(_ kinds: Set<ItemKind>) -> NSPredicate {
        var types: [Int] = []
        if kinds.contains(.photo) || kinds.contains(.livePhoto) { types.append(PHAssetMediaType.image.rawValue) }
        if kinds.contains(.video) { types.append(PHAssetMediaType.video.rawValue) }
        return types.isEmpty ? NSPredicate(value: false) : NSPredicate(format: "mediaType IN %@", types)
    }

    func fullScan(kinds: Set<ItemKind>, batchSize: Int = 2_000, onBatch: @Sendable ([ScannedAsset]) async throws -> Void) async throws -> Int {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = Self.predicate(kinds)
        let result = PHAsset.fetchAssets(with: options)
        var index = 0
        while index < result.count {
            try Task.checkCancellation()
            let upper = min(index + batchSize, result.count)
            let batch: [ScannedAsset] = autoreleasepool {
                result.objects(at: IndexSet(integersIn: index..<upper)).map {
                    ScannedAsset(localID: $0.localIdentifier, kind: Self.kind(of: $0), createdAt: $0.creationDate)
                }
            }
            try await onBatch(batch)
            index = upper
        }
        return result.count
    }

    func currentToken() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    }

    func changes(since tokenData: Data, kinds: Set<ItemKind>) throws -> Changes {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: tokenData) else {
            throw ScanError.tokenExpired
        }
        var inserted = Set<String>()
        var deleted = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                let details = try change.changeDetails(for: PHObjectType.asset)
                inserted.formUnion(details.insertedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
            }
        } catch {
            throw ScanError.tokenExpired
        }
        inserted.subtract(deleted)
        var scanned: [ScannedAsset] = []
        if !inserted.isEmpty {
            let options = PHFetchOptions()
            options.predicate = Self.predicate(kinds)
            PHAsset.fetchAssets(withLocalIdentifiers: Array(inserted), options: options).enumerateObjects { asset, _, _ in
                scanned.append(ScannedAsset(localID: asset.localIdentifier, kind: Self.kind(of: asset), createdAt: asset.creationDate))
            }
        }
        return Changes(inserted: scanned, deleted: Array(deleted), token: currentToken())
    }
}
