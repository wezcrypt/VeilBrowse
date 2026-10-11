import AVFoundation
import UIKit

/// Poster frames via AVAssetImageGenerator. Works for local files and for vault
/// videos streamed through `AuthenticatedResourceLoader` (only the needed byte
/// ranges are fetched).
enum VideoThumbnailGenerator {
    static func image(for asset: AVAsset, maxPixelSize: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let seconds = duration.isFinite && duration > 2 ? 1.0 : 0
        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return UIImage(cgImage: cgImage)
        } catch {
            Log.media.debug("Thumbnail generation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func jpegThumbnail(for asset: AVAsset, maxPixelSize: CGFloat, quality: CGFloat = 0.8) async -> Data? {
        await image(for: asset, maxPixelSize: maxPixelSize)?.jpegData(compressionQuality: quality)
    }
}
