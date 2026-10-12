import Foundation

/// Uploads one prepared chunk file. Implementations must upload from a file on
/// disk so they work with background URLSessions.
protocol ChunkTransport: Sendable {
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data)

    /// True when uploads can outlive the app process (background URLSession).
    var supportsBackgroundHandoff: Bool { get }
    /// While set, cancelling the waiting Swift task does NOT cancel the system
    /// transfer: it keeps running while the app is suspended.
    func setDetachOnCancel(_ detach: Bool)
    /// Starts a transfer nobody waits for (handed to iOS before suspension). Its
    /// result is reconciled with the server on the next pass.
    func enqueueDetached(_ request: URLRequest, fromFile fileURL: URL)
    /// Chunk file names of transfers the system is still running.
    func inFlightFileNames() async -> Set<String>
}

extension ChunkTransport {
    var supportsBackgroundHandoff: Bool { false }
    func setDetachOnCancel(_ detach: Bool) {}
    func enqueueDetached(_ request: URLRequest, fromFile fileURL: URL) {}
    func inFlightFileNames() async -> Set<String> { [] }
}

/// Background URLSession transport: chunks that are in flight keep uploading
/// while the app is suspended. The server is the source of truth for which
/// chunks arrived, so completions delivered while the app was not running are
/// reconciled on the next pass (`GET /uploads/{id}`).
///
/// iOS cancels background transfers if the user force-quits the app from the
/// app switcher; they resume (from the last verified chunk) on next launch.
final class BackgroundChunkTransport: NSObject, ChunkTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>
        var data = Data()
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var detachOnCancel = false
    private var backgroundCompletion: (@MainActor @Sendable () -> Void)?
    private let identifier: String
    private var storedSession: URLSession?

    init(identifier: String = AppConfig.backgroundSessionIdentifier) {
        self.identifier = identifier
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let storedSession { return storedSession }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        // Below the server's per-user limit of concurrent chunk requests, also for
        // transfers iOS runs on its own while the app is suspended.
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        storedSession = created
        return created
    }

    func activate() {
        _ = session
    }

    func setBackgroundCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        backgroundCompletion = handler
        lock.unlock()
        activate()
    }

    var supportsBackgroundHandoff: Bool { true }

    func setDetachOnCancel(_ detach: Bool) {
        lock.lock()
        detachOnCancel = detach
        lock.unlock()
    }

    func enqueueDetached(_ request: URLRequest, fromFile fileURL: URL) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = fileURL.lastPathComponent
        task.resume()
    }

    func inFlightFileNames() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = fileURL.lastPathComponent
        let taskID = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[taskID] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let detach = detachOnCancel
            let entry = detach ? pending.removeValue(forKey: taskID) : nil
            lock.unlock()
            if detach {
                // Suspension: release the waiting Swift task but let iOS finish the upload.
                entry?.continuation.resume(throwing: CancellationError())
            } else {
                task.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else {
            Log.sync.info("Background chunk finished while detached; it will be reconciled with the server")
            return
        }
        if let urlError = error as? URLError {
            entry.continuation.resume(throwing: urlError.code == .cancelled ? CancellationError() : APIError.transport(urlError))
        } else if let error {
            entry.continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            entry.continuation.resume(returning: (response, entry.data))
        } else {
            entry.continuation.resume(throwing: APIError.invalidResponse)
        }
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

/// Foreground transport (used by tests and as a fallback).
final class ForegroundChunkTransport: ChunkTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
        do {
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (http, data)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error)
        }
    }
}
