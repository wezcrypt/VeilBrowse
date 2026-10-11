import AVFoundation
import Observation
import Photos
import PhotosUI
import UIKit

/// Photo library authorization and a live fetch of the device library, ordered by
/// creation date (newest first). Works with Full and Limited access.
@MainActor
@Observable
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: PHFetchResult<PHAsset> = PHFetchResult()
    private(set) var changeCount = 0
    private var isObserving = false

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }
    var isLimited: Bool { authorization == .limited }

    override init() {
        super.init()
        if hasAccess { startObserving() }
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if hasAccess { startObserving() }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = status
        if hasAccess { startObserving() }
    }

    func presentLimitedLibraryPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func startObserving() {
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        reload()
    }

    func reload() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        assets = PHAsset.fetchAssets(with: options)
        changeCount += 1
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            self?.reload()
        }
    }

    func asset(at index: Int) -> PHAsset? {
        guard index >= 0, index < assets.count else { return nil }
        return assets.object(at: index)
    }
}

/// Async thumbnail requests for device assets with cancellation support.
@MainActor
enum LocalImageRequester {
    private static let manager = PHCachingImageManager()

    static func image(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode = .aspectFill, highQuality: Bool = false) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        options.resizeMode = highQuality ? .exact : .fast
        options.isSynchronous = false
        let requestID = LockedBox<PHImageRequestID?>(nil)
        let finished = LockedBox(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<UIImage?>, Never>) in
                let id = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { @Sendable image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let failed = info?[PHImageErrorKey] != nil
                    // Opportunistic delivery may call back twice; resume on the final image only.
                    if degraded && !cancelled && !failed { return }
                    let shouldResume = finished.withValue { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if shouldResume { continuation.resume(returning: UncheckedSendable(image)) }
                }
                requestID.value = id
            }.value
        } onCancel: {
            if let id = requestID.value {
                Task { @MainActor in manager.cancelImageRequest(id) }
            }
        }
    }

    static func playerItem(for asset: PHAsset) async throws -> AVPlayerItem {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let result: UncheckedSendable<AVPlayerItem?> = await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { @Sendable item, _ in
                continuation.resume(returning: UncheckedSendable(item))
            }
        }
        guard let item = result.value else { throw AssetExportError.unavailable }
        return item
    }
}
