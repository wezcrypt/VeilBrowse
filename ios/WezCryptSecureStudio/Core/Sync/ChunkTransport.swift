import Foundation

/// Uploads chunk files through a background `URLSession`, so a chunk that is in
/// flight keeps transferring when the app is suspended. The server is the source
/// of truth for upload offsets, so tasks that complete while the app is not
/// running are simply reconciled on the next sync pass.
final class ChunkTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
        var data = Data()
        let fileURL: URL
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var orphanData: [Int: Data] = [:]
    private var backgroundCompletion: (@MainActor @Sendable () -> Void)?
    private let identifier: String
    private var sessionStorage: URLSession?

    init(identifier: String = AppConfig.backgroundUploadSessionIdentifier) {
        self.identifier = identifier
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let sessionStorage { return sessionStorage }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionStorage = created
        return created
    }

    /// Re-attaches to the background session after a relaunch.
    func activate() {
        _ = session
    }

    func setBackgroundCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        backgroundCompletion = handler
        lock.unlock()
        activate()
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = fileURL.path
        let taskID = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[taskID] = Pending(continuation: continuation, fileURL: fileURL)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if pending[dataTask.taskIdentifier] != nil {
            pending[dataTask.taskIdentifier]?.data.append(data)
        } else {
            orphanData[dataTask.taskIdentifier, default: Data()].append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        orphanData.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        let fileURL = entry?.fileURL ?? task.taskDescription.map { URL(fileURLWithPath: $0) }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }

        guard let entry else {
            Log.sync.info("Background chunk finished while detached; offset will be reconciled")
            return
        }
        if let error {
            if let urlError = error as? URLError {
                entry.continuation.resume(throwing: urlError.code == .cancelled ? CancellationError() : APIError.transport(urlError))
            } else {
                entry.continuation.resume(throwing: error)
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            entry.continuation.resume(throwing: APIError.invalidResponse)
            return
        }
        entry.continuation.resume(returning: (response, entry.data))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        if let handler {
            Task { @MainActor in handler() }
        }
    }
}
