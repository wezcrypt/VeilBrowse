import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Streams vault media into AVPlayer using the documented
/// `AVAssetResourceLoaderDelegate` mechanism: AVFoundation asks for byte ranges
/// of a custom-scheme URL, and each range is fetched with an authenticated HTTP
/// Range request. Tokens never appear in URLs, and nothing is written to disk.
final class AuthenticatedResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "wzcvault"
    /// Size of each HTTP range request. AVPlayer often asks for "everything to
    /// the end"; slicing keeps memory bounded and makes seeking cancel quickly.
    static let sliceSize: Int64 = 2 * 1024 * 1024

    let queue = DispatchQueue(label: "com.wezcrypt.securestudio.resourceloader")
    private let api: APIClient
    private let mediaID: String
    private let mimeType: String
    private let tasks = LockedBox<[ObjectIdentifier: Task<Void, Never>]>([:])

    init(api: APIClient, mediaID: String, mimeType: String) {
        self.api = api
        self.mediaID = mediaID
        self.mimeType = mimeType
    }

    static func assetURL(for mediaID: String) -> URL {
        URL(string: "\(scheme)://media/\(mediaID)")!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        let key = ObjectIdentifier(loadingRequest)
        let request = UncheckedSendable(loadingRequest)
        let task = Task { [api, mediaID, mimeType, tasks] in
            await Self.serve(request.value, api: api, mediaID: mediaID, mimeType: mimeType)
            tasks.withValue { _ = $0.removeValue(forKey: key) }
        }
        tasks.withValue { $0[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        tasks.withValue { $0.removeValue(forKey: key) }?.cancel()
    }

    func cancelAll() {
        let all = tasks.withValue { tasks -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        all.forEach { $0.cancel() }
    }

    private static func fillContentInfo(_ info: AVAssetResourceLoadingContentInformationRequest, total: Int64, mime: String) {
        let type = UTType(mimeType: mime) ?? UTType(mimeType: "video/mp4") ?? .movie
        info.contentType = type.identifier
        info.contentLength = total
        info.isByteRangeAccessSupported = true
    }

    private static func serve(_ request: AVAssetResourceLoadingRequest, api: APIClient, mediaID: String, mimeType: String) async {
        do {
            guard let dataRequest = request.dataRequest else {
                if let info = request.contentInformationRequest {
                    let probe = try await api.contentRange(mediaID, range: 0...1)
                    fillContentInfo(info, total: probe.totalLength, mime: mimeType)
                }
                request.finishLoading()
                return
            }
            var offset = dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
            let requestedEnd: Int64? = dataRequest.requestsAllDataToEndOfResource
                ? nil
                : dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
            var total: Int64?
            var infoFilled = request.contentInformationRequest == nil
            while true {
                try Task.checkCancellation()
                var end = offset + sliceSize - 1
                if let requestedEnd { end = min(end, requestedEnd) }
                if let total { end = min(end, total - 1) }
                if end < offset { break }
                let result = try await api.contentRange(mediaID, range: offset...end)
                total = result.totalLength
                if !infoFilled, let info = request.contentInformationRequest {
                    fillContentInfo(info, total: result.totalLength, mime: mimeType)
                    infoFilled = true
                }
                try Task.checkCancellation()
                if result.data.isEmpty { break }
                dataRequest.respond(with: result.data)
                offset += Int64(result.data.count)
                if let requestedEnd, offset > requestedEnd { break }
                if offset >= result.totalLength { break }
            }
            request.finishLoading()
        } catch is CancellationError {
            // AVFoundation cancelled the request (seek, dismissal); nothing to report.
        } catch {
            Log.media.error("Range load failed: \(error.localizedDescription, privacy: .public)")
            request.finishLoading(with: error)
        }
    }
}
