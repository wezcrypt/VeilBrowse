import Foundation
import Photos

struct ActiveUpload: Sendable, Identifiable, Equatable {
    enum Stage: String, Sendable {
        case preparing
        case downloading
        case hashing
        case uploading
        case finalizing

        var title: String {
            switch self {
            case .preparing: return String(localized: "Preparing")
            case .downloading: return String(localized: "Downloading from iCloud")
            case .hashing: return String(localized: "Verifying")
            case .uploading: return String(localized: "Uploading")
            case .finalizing: return String(localized: "Finalizing")
            }
        }
    }

    let id: String
    var filename: String?
    var stage: Stage = .preparing
    var totalBytes: Int64 = 0
    var sentBytes: Int64 = 0
    var downloadProgress: Double = 0

    var fraction: Double {
        switch stage {
        case .downloading: return downloadProgress * 0.2
        case .uploading, .finalizing: return totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 0
        default: return 0
        }
    }
}

enum SyncPhase: Sendable, Equatable {
    case idle
    case scanning(discovered: Int)
    case uploading
    case waiting(String)
    case paused
    case needsPermission
    case signedOut
    case finished(Date)
    case failed(String)
}

struct SyncSnapshot: Sendable, Equatable {
    var phase: SyncPhase = .idle
    var counts = SyncCounts()
    var active: [ActiveUpload] = []
    var bytesPerSecond: Double = 0
    var remainingBytesEstimate: Int64 = 0
    var etaSeconds: Double?
    var sessionUploadedBytes: Int64 = 0
    var sessionCompleted = 0
    var isRunning = false
}

/// Sliding-window throughput estimate.
struct ThroughputMeter: Sendable {
    private var samples: [(Date, Int64)] = []
    var window: TimeInterval = 10

    mutating func add(_ bytes: Int64, at date: Date = Date()) {
        samples.append((date, bytes))
        trim(now: date)
    }

    mutating func rate(now: Date = Date()) -> Double {
        trim(now: now)
        guard let first = samples.first else { return 0 }
        let total = samples.reduce(Int64(0)) { $0 + $1.1 }
        let elapsed = max(now.timeIntervalSince(first.0), 1)
        return Double(total) / elapsed
    }

    private mutating func trim(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.0) > window }
    }
}

enum SyncInterruption: Error {
    case networkUnavailable
}

/// The Sync All engine: scans the photo library (full or incremental via
/// persistent change tokens), queues un-uploaded assets, and uploads them with
/// resumable SHA-256-verified chunks and bounded concurrency.
actor SyncEngine {
    private let store: SyncStore
    private let api: APIClient
    private let transport: ChunkTransport
    private let network: NetworkMonitor
    private let scanner = LibraryScanner()
    private let exporter: AssetExporter
    private let chunkDirectory: URL
    private let workDirectory: URL

    private var policy: SyncPolicy
    private var runTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var runID = 0
    private var isPaused = false
    private var snapshot = SyncSnapshot()
    private var active: [String: ActiveUpload] = [:]
    private var meter = ThroughputMeter()
    private var averageBytes: Int64 = 3_000_000
    private var continuations: [UUID: AsyncStream<SyncSnapshot>.Continuation] = [:]
    private var lastPublish = Date.distantPast
    private var publishPending = false
    private var lastCountsRefresh = Date.distantPast

    init(store: SyncStore, api: APIClient, transport: ChunkTransport, network: NetworkMonitor, policy: SyncPolicy) throws {
        self.store = store
        self.api = api
        self.transport = transport
        self.network = network
        self.policy = policy
        let work = try AppDirectories.secureTemp("SyncExports")
        let chunks = try AppDirectories.caches("UploadChunks")
        // Leftovers from a previous process are never needed again.
        for directory in [work] {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        workDirectory = work
        chunkDirectory = chunks
        exporter = AssetExporter(workDirectory: work)
    }

    // MARK: - Public API

    func snapshots() -> AsyncStream<SyncSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func updatePolicy(_ policy: SyncPolicy) {
        self.policy = policy
    }

    var isRunning: Bool { runTask != nil }

    /// Starts a sync pass if none is running. `fullScan` re-enumerates the whole library.
    func start(fullScan: Bool) {
        guard runTask == nil else { return }
        isPaused = false
        runID += 1
        let id = runID
        let previous = drainingTask
        snapshot.isRunning = true
        runTask = Task {
            await previous?.value
            await self.run(fullScan: fullScan)
            await self.runEnded(id)
        }
        publish(force: true)
    }

    func pause() {
        isPaused = true
        drainingTask = runTask
        runTask?.cancel()
        runTask = nil
        snapshot.isRunning = false
        setPhase(.paused)
    }

    func resume() {
        start(fullScan: false)
    }

    /// Cancels the current pass without marking the engine as paused (background expiry).
    func cancelRun() {
        drainingTask = runTask
        runTask?.cancel()
        runTask = nil
        snapshot.isRunning = false
        publish(force: true)
    }

    func waitForCurrentRun() async {
        await runTask?.value
    }

    func retryFailed() async {
        _ = try? await store.retryAllFailed()
        await refreshCounts(force: true)
        start(fullScan: false)
    }

    func retry(_ localID: String) async {
        try? await store.retry(localID)
        await refreshCounts(force: true)
        start(fullScan: false)
    }

    /// Sign-out: stop everything and forget all local sync state.
    func reset() async {
        drainingTask = runTask
        runTask?.cancel()
        runTask = nil
        await drainingTask?.value
        try? await store.reset()
        active.removeAll()
        meter = ThroughputMeter()
        snapshot = SyncSnapshot()
        for directory in [workDirectory, chunkDirectory] {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        publish(force: true)
    }

    func refreshCounts(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastCountsRefresh) > 1 else { return }
        lastCountsRefresh = Date()
        if let counts = try? await store.counts() {
            snapshot.counts = counts
            publish()
        }
    }

    // MARK: - Run loop

    private func runEnded(_ id: Int) {
        if id == runID {
            runTask = nil
            snapshot.isRunning = false
            publish(force: true)
        }
    }

    private func run(fullScan: Bool) async {
        guard await api.credentials.current() != nil else {
            setPhase(.signedOut)
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            setPhase(.needsPermission)
            return
        }
        do {
            try await scan(full: fullScan)
            try await store.resetStaleUploading()
            await refreshCounts(force: true)
            if let average = try await store.averageCompletedBytes(), average > 0 { averageBytes = average }
            try await processQueue()
            try Task.checkCancellation()
            setPhase(.finished(Date()))
        } catch is CancellationError {
            setPhase(isPaused ? .paused : .idle)
        } catch let error as APIError where error == .sessionRevoked || error == .notSignedIn {
            setPhase(.signedOut)
        } catch {
            Log.sync.error("Sync pass failed: \(error.localizedDescription, privacy: .public)")
            setPhase(.failed(error.localizedDescription))
        }
        active.removeAll()
        await refreshCounts(force: true)
    }

    private func scan(full: Bool) async throws {
        setPhase(.scanning(discovered: 0))
        let kinds = policy.mediaKinds
        let kindsKey = kinds.map(\.rawValue).joined(separator: ",")
        let storedKinds = try await store.metaData("scan.kinds").flatMap { String(data: $0, encoding: .utf8) }
        if !full, storedKinds == kindsKey, let tokenData = try await store.metaData("scan.token") {
            do {
                let changes = try scanner.changes(since: tokenData, kinds: kinds)
                let generation = try await store.metaInt("scan.generation") ?? 0
                let inserted = try await store.upsertScanned(changes.inserted, generation: generation)
                try await store.removeDeleted(changes.deleted)
                try await store.setMetaData("scan.token", changes.token)
                Log.sync.info("Incremental scan: \(inserted) new, \(changes.deleted.count) deleted")
                return
            } catch LibraryScanner.ScanError.tokenExpired {
                Log.sync.notice("Change token expired; running a full scan")
            }
        }
        // Capture the token first so changes made during the scan are picked up next time.
        let token = scanner.currentToken()
        let generation = try await store.nextGeneration()
        let total = try await scanner.fullScan(kinds: kinds) { [weak self] batch in
            try await self?.ingest(batch, generation: generation)
        }
        try await store.pruneUnseen(generation: generation)
        try await store.setMetaData("scan.token", token)
        try await store.setMetaData("scan.kinds", Data(kindsKey.utf8))
        Log.sync.info("Full scan finished: \(total) assets")
    }

    private func ingest(_ batch: [ScannedAsset], generation: Int64) async throws {
        try await store.upsertScanned(batch, generation: generation)
        if case .scanning(let discovered) = snapshot.phase {
            setPhase(.scanning(discovered: discovered + batch.count))
        }
    }

    private func processQueue() async throws {
        var inFlight = Set<String>()
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            while true {
                try Task.checkCancellation()
                let currentPolicy = policy
                let status = network.status
                if !status.allows(currentPolicy), inFlight.isEmpty {
                    setPhase(.waiting(status.blockReason(currentPolicy) ?? String(localized: "Waiting for network")))
                    try await network.waitUntilAllowed(currentPolicy)
                    continue
                }
                if snapshot.phase != .uploading { setPhase(.uploading) }

                let capacity = currentPolicy.maxConcurrentUploads - inFlight.count
                if capacity > 0, status.allows(currentPolicy) {
                    let batch = try await store.nextPending(limit: capacity, kinds: currentPolicy.mediaKinds, excluding: inFlight)
                    for record in batch {
                        inFlight.insert(record.localID)
                        group.addTask { [self] in
                            await self.process(record)
                            return record.localID
                        }
                    }
                }

                if inFlight.isEmpty {
                    if let next = try await store.earliestRetryDate(kinds: currentPolicy.mediaKinds),
                       next > Date(), next.timeIntervalSinceNow < 180 {
                        setPhase(.waiting(String(localized: "Retrying shortly")))
                        try await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSinceNow, 1) * 1_000_000_000))
                        continue
                    }
                    return
                }
                if let finished = try await group.next() {
                    inFlight.remove(finished)
                }
            }
        }
    }

    // MARK: - Per-asset pipeline (runs off the actor)

    private nonisolated func process(_ record: SyncRecord) async {
        let localID = record.localID
        var exportedURL: URL?
        defer {
            if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        }
        do {
            try await store.markUploading(localID)
            await beginActive(localID, filename: record.filename)

            let asset = try await exporter.export(localIdentifier: localID) { [weak self] value in
                Task { await self?.updateDownload(localID, progress: value) }
            }
            exportedURL = asset.fileURL
            await updateActive(localID, stage: .hashing, filename: asset.filename, total: asset.size)

            let sha256 = try FileHasher.sha256Hex(of: asset.fileURL)
            try await store.updateFileInfo(localID, sha256: sha256, bytes: asset.size, filename: asset.filename)

            let request = CreateUploadRequest(
                filename: asset.filename,
                mimeType: asset.mimeType,
                mediaType: asset.kind,
                sizeBytes: asset.size,
                sha256: sha256,
                takenAt: asset.creationDate.map { Int($0.timeIntervalSince1970) },
                width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
                height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
                durationMs: asset.durationMs,
                isFavorite: asset.isFavorite,
                isScreenshot: asset.isScreenshot,
                localIdentifier: nil
            )
            let created = try await api.createUpload(request)
            if created.status == "duplicate", let media = created.media {
                try await store.markCompleted(localID, remoteMediaID: media.id)
                await finishActive(localID, uploadedBytes: 0, succeeded: true)
                return
            }
            guard let uploadID = created.uploadId, let chunkSize = created.chunkSize, chunkSize > 0 else {
                throw APIError.invalidResponse
            }
            try await store.setUploadID(localID, uploadID: uploadID)

            var offset = created.offset ?? 0
            await updateActive(localID, stage: .uploading, sent: offset)
            let file = try FileHandle(forReadingFrom: asset.fileURL)
            defer { try? file.close() }
            while offset < asset.size {
                try Task.checkCancellation()
                let currentPolicy = await currentPolicy()
                guard network.status.allows(currentPolicy) else { throw SyncInterruption.networkUnavailable }
                let length = Int(min(Int64(chunkSize), asset.size - offset))
                try file.seek(toOffset: UInt64(offset))
                guard let chunk = try file.read(upToCount: length), chunk.count == length else {
                    throw AssetExportError.unavailable
                }
                do {
                    let newOffset = try await sendChunk(uploadID: uploadID, offset: offset, data: chunk, policy: currentPolicy)
                    await recordProgress(localID, sent: newOffset, delta: max(newOffset - offset, 0))
                    offset = newOffset
                } catch let error as APIError where error.code == "offset_mismatch" {
                    guard let serverOffset = Self.offset(from: error) else { throw error }
                    offset = serverOffset
                    await updateActive(localID, stage: .uploading, sent: offset)
                }
            }

            await updateActive(localID, stage: .finalizing, sent: asset.size)
            let completed = try await api.completeUpload(uploadID)
            if let thumbnail = await AssetExporter.makeThumbnail(for: asset) {
                do {
                    try await api.uploadThumbnail(completed.media.id, jpeg: thumbnail)
                } catch {
                    Log.sync.notice("Thumbnail upload failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try await store.markCompleted(localID, remoteMediaID: completed.media.id)
            await finishActive(localID, uploadedBytes: asset.size, succeeded: true)
        } catch {
            await handleFailure(localID, error: error, previousAttempts: record.attempts)
        }
    }

    private static func offset(from error: APIError) -> Int64? {
        if case .server(_, _, _, let offset) = error { return offset }
        return nil
    }

    private nonisolated func sendChunk(uploadID: String, offset: Int64, data: Data, policy: SyncPolicy) async throws -> Int64 {
        let chunkURL = chunkDirectory.appendingPathComponent(UUID().uuidString + ".chunk")
        let checksum = "sha256 " + FileHasher.sha256Base64(data)

        func makeRequest(token: String) throws -> URLRequest {
            var request = try api.makeRequest(Endpoint(method: "PATCH", path: "/api/mobile/uploads/\(uploadID)", timeout: 120), accessToken: token)
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            request.setValue(checksum, forHTTPHeaderField: "Upload-Checksum")
            let cellularAllowed = policy.networkMode == .wifiAndCellular
            request.allowsCellularAccess = cellularAllowed
            request.allowsExpensiveNetworkAccess = cellularAllowed
            request.allowsConstrainedNetworkAccess = !policy.respectLowDataMode
            return request
        }

        func attempt(token: String) async throws -> (HTTPURLResponse, Data) {
            try data.write(to: chunkURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            do {
                return try await transport.upload(try makeRequest(token: token), fromFile: chunkURL)
            } catch {
                try? FileManager.default.removeItem(at: chunkURL)
                throw error
            }
        }

        var (response, body) = try await attempt(token: try await api.validAccessToken())
        if response.statusCode == 401 {
            let refreshed = try await api.forceRefresh()
            (response, body) = try await attempt(token: refreshed.accessToken)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.from(status: response.statusCode, data: body)
        }
        do {
            return try APIClient.makeDecoder().decode(UploadProgressResponse.self, from: body).offset
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func handleFailure(_ localID: String, error: Error, previousAttempts: Int) async {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        do {
            if error is CancellationError || error is SyncInterruption {
                try await store.markPending(localID, error: nil, retryAfter: nil, countAttempt: false)
            } else if let apiError = error as? APIError, apiError == .sessionRevoked || apiError == .notSignedIn {
                try await store.markPending(localID, error: nil, retryAfter: nil, countAttempt: false)
                runTask?.cancel()
            } else if let apiError = error as? APIError, apiError.code == "hash_mismatch" {
                try await store.clearHash(localID)
                try await store.markPending(localID, error: message, retryAfter: Date().addingTimeInterval(30), countAttempt: true)
            } else if Self.isRetryable(error) {
                if previousAttempts + 1 >= AppConfig.maxUploadAttempts {
                    try await store.markFailed(localID, error: message)
                } else {
                    let delay = Backoff().delay(forAttempt: previousAttempts + 1)
                    try await store.markPending(localID, error: message, retryAfter: Date().addingTimeInterval(delay), countAttempt: true)
                }
            } else {
                try await store.markFailed(localID, error: message)
            }
        } catch {
            Log.sync.error("Failed to persist sync failure: \(error.localizedDescription, privacy: .public)")
        }
        if !(error is CancellationError) {
            Log.sync.notice("Upload of asset failed: \(message, privacy: .public)")
        }
        finishActive(localID, uploadedBytes: 0, succeeded: false)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? APIError { return apiError.isRetryable }
        if let exportError = error as? AssetExportError, case .iCloudDownloadFailed = exportError { return true }
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
    }

    // MARK: - Progress bookkeeping

    private func currentPolicy() -> SyncPolicy { policy }

    private func beginActive(_ localID: String, filename: String?) {
        active[localID] = ActiveUpload(id: localID, filename: filename)
        publish()
    }

    private func updateDownload(_ localID: String, progress: Double) {
        guard var item = active[localID] else { return }
        item.stage = .downloading
        item.downloadProgress = progress
        active[localID] = item
        publish()
    }

    private func updateActive(_ localID: String, stage: ActiveUpload.Stage, filename: String? = nil, total: Int64? = nil, sent: Int64? = nil) {
        guard var item = active[localID] else { return }
        item.stage = stage
        if let filename { item.filename = filename }
        if let total { item.totalBytes = total }
        if let sent { item.sentBytes = sent }
        active[localID] = item
        publish()
    }

    private func recordProgress(_ localID: String, sent: Int64, delta: Int64) {
        meter.add(delta)
        snapshot.sessionUploadedBytes += delta
        updateActive(localID, stage: .uploading, sent: sent)
    }

    private func finishActive(_ localID: String, uploadedBytes: Int64, succeeded: Bool) {
        active.removeValue(forKey: localID)
        if succeeded {
            snapshot.sessionCompleted += 1
            if uploadedBytes > 0 {
                averageBytes = (averageBytes * 9 + uploadedBytes) / 10
            }
        }
        Task { await self.refreshCounts() }
        publish()
    }

    private func setPhase(_ phase: SyncPhase) {
        guard snapshot.phase != phase else { return }
        snapshot.phase = phase
        publish(force: true)
    }

    private func publish(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < 0.25 {
            if !publishPending {
                publishPending = true
                Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await self.flushPending()
                }
            }
            return
        }
        lastPublish = now
        publishPending = false
        snapshot.active = active.values.sorted { $0.id < $1.id }
        snapshot.bytesPerSecond = meter.rate(now: now)
        let activeRemaining = active.values.reduce(Int64(0)) { $0 + max($1.totalBytes - $1.sentBytes, 0) }
        let queued = Int64(max(snapshot.counts.pending - active.count, 0))
        snapshot.remainingBytesEstimate = activeRemaining + queued * averageBytes
        snapshot.etaSeconds = snapshot.bytesPerSecond > 1024 ? Double(snapshot.remainingBytesEstimate) / snapshot.bytesPerSecond : nil
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func flushPending() {
        guard publishPending else { return }
        publish(force: true)
    }
}
