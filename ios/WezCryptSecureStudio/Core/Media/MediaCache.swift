import Foundation
import UIKit

/// Disk cache of *encrypted* objects (WZCE ciphertext exactly as stored on the
/// server) for the photo viewer, video player and thumbnails. Nothing decrypted is
/// ever cached on disk: plaintext only exists in memory (thumbnails, decoded
/// images) or in short-lived files in `ViewerFiles` that are deleted when a page
/// closes, at launch, on sign-out and when the app locks.
///
/// Least-recently-used eviction keeps the cache under `limitBytes`.
actor MediaCache {
    static let shared = MediaCache()

    let directory: URL
    var limitBytes: Int64 = 1_000_000_000

    init(directory: URL? = nil) {
        self.directory = directory ?? ((try? AppDirectories.caches("EncryptedMedia")) ?? FileManager.default.temporaryDirectory.appendingPathComponent("EncryptedMedia"))
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var inFlight: [String: Task<URL, Error>] = [:]

    func setLimit(_ bytes: Int64) {
        limitBytes = max(bytes, 0)
    }

    func cachedURL(_ objectID: String) -> URL? {
        let url = directory.appendingPathComponent(objectID + ".wzce")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Returns the encrypted object on disk, downloading it once (concurrent callers share the download).
    func encryptedObject(_ objectID: String, expectedSize: Int64?, api: BackupAPI,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = cachedURL(objectID) { progress?(1); return cached }
        if let running = inFlight[objectID] { return try await running.value }
        if let expectedSize { try StorageGuard().ensure(expectedSize) }
        let destination = directory.appendingPathComponent(objectID + ".wzce")
        let task = Task<URL, Error> {
            let temp = try await ProgressDownloader.download(objectID: objectID, api: api, progress: progress)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        }
        inFlight[objectID] = task
        defer { inFlight[objectID] = nil }
        let url = try await task.value
        trim()
        return url
    }

    /// Current size of the cache in bytes.
    func size() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    func trim() {
        var files = entries()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limitBytes else { return }
        files.sort { $0.date < $1.date }
        for file in files where total > limitBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    func clear() {
        for file in entries() { try? FileManager.default.removeItem(at: file.url) }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "wzce", let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}

/// Short-lived decrypted files for the viewer (complete file protection).
enum ViewerFiles {
    static var directory: URL {
        (try? AppDirectories.secureTemp("ViewerFiles")) ?? FileManager.default.temporaryDirectory.appendingPathComponent("ViewerFiles")
    }

    static func newFolder() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return folder
    }

    static func wipeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Downloads one object with byte progress (the async `URLSession.download` API
/// reports none). Uses an ephemeral, cookie-less session with TLS 1.2+.
final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private let lock = NSLock()

    private init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    static func download(objectID: String, api: BackupAPI, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        func attempt(token: String) async throws -> (URL, HTTPURLResponse) {
            let request = try api.request("GET", "/api/v2/objects/\(objectID)", token: token, timeout: 900)
            let downloader = ProgressDownloader(progress: progress)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
            configuration.timeoutIntervalForRequest = api.configuration.requestTimeout
            configuration.timeoutIntervalForResource = 6 * 3600
            let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                    downloader.lock.lock()
                    downloader.continuation = continuation
                    downloader.lock.unlock()
                    session.downloadTask(with: request).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
        }
        var (file, response) = try await attempt(token: try await api.bearerToken())
        if response.statusCode == 401, api.configuration.authMethod == .password {
            try? FileManager.default.removeItem(at: file)
            try await api.login()
            (file, response) = try await attempt(token: try await api.bearerToken())
        }
        guard (200..<300).contains(response.statusCode) else {
            let data = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            api.observe(response, data: data)
            throw APIError.from(status: response.statusCode, data: data)
        }
        return file
    }

    private func finish(_ result: Result<(URL, HTTPURLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns: move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            guard let response = downloadTask.response as? HTTPURLResponse else { throw APIError.invalidResponse }
            finish(.success((kept, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let urlError = error as? URLError {
            finish(.failure(urlError.code == .cancelled ? CancellationError() : APIError.transport(urlError)))
        } else {
            finish(.failure(error))
        }
    }
}
