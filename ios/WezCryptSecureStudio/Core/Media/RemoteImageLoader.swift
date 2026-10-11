import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// Loads vault thumbnails with a bounded memory cache, an encrypted disk cache
/// and request coalescing.
actor RemoteImageLoader {
    struct Request: Sendable {
        let mediaID: String
        let hasThumbnail: Bool
        let isVideo: Bool
        let mimeType: String

        init(item: MediaItem) {
            mediaID = item.id
            hasThumbnail = item.hasThumbnail
            isVideo = item.isVideo
            mimeType = item.mimeType
        }

        /// Covers of albums and buckets: the server returns 404 when no thumbnail exists.
        init(coverID: String) {
            mediaID = coverID
            hasThumbnail = true
            isVideo = false
            mimeType = "image/jpeg"
        }
    }

    private let api: APIClient
    private let crypto: LocalCacheCrypto
    // NSCache is internally thread-safe.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL?

    init(api: APIClient, crypto: LocalCacheCrypto) {
        self.api = api
        self.crypto = crypto
        memory.countLimit = 800
        memory.totalCostLimit = 120 * 1024 * 1024
        directory = try? AppDirectories.caches("Thumbnails")
    }

    nonisolated func cachedThumbnail(_ id: String) -> UIImage? {
        memory.object(forKey: id as NSString)
    }

    func thumbnail(for item: MediaItem, pixelSize: CGFloat) async -> UIImage? {
        await thumbnail(Request(item: item), pixelSize: pixelSize)
    }

    func thumbnail(_ request: Request, pixelSize: CGFloat) async -> UIImage? {
        let id = request.mediaID
        if let cached = memory.object(forKey: id as NSString) { return cached }
        if let task = inFlight[id] { return await task.value }
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) { [api, crypto, directory] in
            if let directory, let image = Self.readDisk(id, directory: directory, crypto: crypto, pixelSize: pixelSize) {
                return image
            }
            var data: Data?
            if request.hasThumbnail {
                data = try? await api.thumbnailData(id)
            }
            if data == nil, request.isVideo {
                let asset = AVURLAsset(url: AuthenticatedResourceLoader.assetURL(for: id))
                let loader = AuthenticatedResourceLoader(api: api, mediaID: id, mimeType: request.mimeType)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                data = await VideoThumbnailGenerator.jpegThumbnail(for: asset, maxPixelSize: 512)
                loader.cancelAll()
            }
            guard let data, !Task.isCancelled else { return nil }
            if let directory, let sealed = try? crypto.seal(data) {
                try? sealed.write(to: Self.diskURL(id, directory: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            return await ImageDownsampler.downsample(data: data, maxPixelSize: pixelSize)?.byPreparingForDisplay()
        }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: id as NSString, cost: cost)
        }
        return image
    }

    private static func diskURL(_ id: String, directory: URL) -> URL {
        directory.appendingPathComponent(FileHasher.sha256Hex(Data(id.utf8)) + ".wzc")
    }

    private static func readDisk(_ id: String, directory: URL, crypto: LocalCacheCrypto, pixelSize: CGFloat) -> UIImage? {
        let url = diskURL(id, directory: directory)
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        guard let data = try? crypto.open(sealed) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return ImageDownsampler.downsample(data: data, maxPixelSize: pixelSize)
    }

    func evict(_ ids: [String]) {
        for id in ids {
            memory.removeObject(forKey: id as NSString)
            if let directory {
                try? FileManager.default.removeItem(at: Self.diskURL(id, directory: directory))
            }
        }
    }

    func clear() {
        memory.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        if let directory {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func diskUsage() -> Int64 {
        directory.map(AppDirectories.directorySize) ?? 0
    }
}

/// Image view for an album/bucket cover identified only by media id.
struct CoverThumbnail: View {
    let mediaID: String?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.placeholder
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .task(id: mediaID) {
                guard let mediaID else { image = nil; return }
                if let cached = env.images.cachedThumbnail(mediaID) { image = cached; return }
                image = await env.images.thumbnail(.init(coverID: mediaID), pixelSize: max(proxy.size.width, proxy.size.height) * displayScale)
            }
        }
        .accessibilityHidden(true)
    }
}
