import AVFoundation
import Foundation
import Photos
import UniformTypeIdentifiers

enum SyncPhase: Sendable, Equatable {
    case idle
    case scanning(Int)
    case running
    case waiting(String)
    case paused
    case finished(Date)
    case failed(String)
    case needsSetup(String)
}

struct ActiveTransfer: Sendable, Identifiable, Equatable {
    enum Stage: String, Sendable {
        case exporting, encrypting, uploading, verifying

        var title: String {
            switch self {
            case .exporting: return String(localized: "Reading original")
            case .encrypting: return String(localized: "Encrypting")
            case .uploading: return String(localized: "Uploading")
            case .verifying: return String(localized: "Verifying")
            }
        }
    }

    let id: String
    var name: String
    var stage: Stage
    var sentBytes: Int64 = 0
    var totalBytes: Int64 = 0

    var fraction: Double { totalBytes > 0 ? min(1, Double(sentBytes) / Double(totalBytes)) : 0 }
}

struct SyncSnapshot: Sendable, Equatable {
    var phase: SyncPhase = .idle
    var counts = QueueCounts()
    var active: [ActiveTransfer] = []
    var bytesPerSecond: Double = 0
    /// Average over the last two minutes; used for the time estimate.
    var averageBytesPerSecond: Double = 0
    var sessionBytes: Int64 = 0
    var remainingBytes: Int64 = 0
    /// Plaintext bytes already backed up from this device.
    var uploadedBytes: Int64 = 0
    var etaSeconds: Double?
    /// Parallel uploads allowed by device conditions and settings.
    var concurrency = 0
    /// Parallel uploads currently used (adaptive, never above `concurrency`).
    var adaptiveLimit = 1
    var activeConnections = 0
    var openServerSessions = 0
    var blockReason: String?
    /// Set while the server asked us to slow down (HTTP 429/503).
    var serverBusyUntil: Date?
    var serverBusyReason: String?
    /// Chunks postponed because of server pressure (not counted as failures).
    var deferredByServer = 0
    var waitingRetryAssets = 0
    var waitingRetryChunks = 0
    var lastError: String?
    var isRunning = false
}

struct SyncEnvironment: Sendable {
    var settings: @Sendable () async -> SyncSettings
    var conditions: @Sendable () async -> DeviceConditions
    var photosAuthorized: @Sendable () -> Bool = {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
}

struct SyncDirectories: Sendable {
    let exports: URL
    let chunks: URL
    let staging: URL

    static func standard() throws -> SyncDirectories {
        SyncDirectories(
            exports: try AppDirectories.secureTemp("Exports"),
            chunks: try AppDirectories.applicationSupport().appendingPathComponent("Chunks", isDirectory: true).createdDirectory(),
            staging: try AppDirectories.applicationSupport().appendingPathComponent("Staging", isDirectory: true).createdDirectory()
        )
    }
}

/// The backup engine. Each pass: discover new photos/videos (incremental via
/// persistent change tokens), encrypt originals into chunk files on disk, upload
/// chunks in parallel through a background URLSession, have the server verify
/// every chunk and the whole object (SHA-256), then register the item. An asset
/// is only marked backed up after the server confirmed the complete object.
actor SyncEngine {
    private let store: QueueStore
    private let keyVault: KeyVault
    private let transport: ChunkTransport
    private let network: NetworkMonitor
    private let environment: SyncEnvironment
    private let dirs: SyncDirectories
    private let storage: StorageGuard
    private let scanner = LibraryScanner()
    private var api: BackupAPI?

    private var runTask: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var runID = 0
    private var paused = false
    private var snapshot = SyncSnapshot()
    private var active: [String: ActiveTransfer] = [:]
    private var meter = ThroughputMeter()
    private var adaptive = AdaptiveConcurrency(ceiling: 4)
    private var deferred = Set<String>()
    /// Items encrypted ahead of the upload: bounded by count as well as bytes, so the
    /// queue on disk (and the work lost if iOS kills the app) stays small.
    var maxPreparedAssets = 24
    private var continuations: [UUID: AsyncStream<SyncSnapshot>.Continuation] = [:]
    private var lastPublish = Date.distantPast
    private var publishPending = false

    /// Maximum encrypted bytes waiting on disk before preparation pauses.
    var preparedWindow: Int64 = 512_000_000

    init(store: QueueStore, keyVault: KeyVault, transport: ChunkTransport, network: NetworkMonitor,
         environment: SyncEnvironment, directories: SyncDirectories, storage: StorageGuard = StorageGuard()) {
        self.store = store
        self.keyVault = keyVault
        self.transport = transport
        self.network = network
        self.environment = environment
        self.dirs = directories
        self.storage = storage
    }

    // MARK: - Control

    func configure(api: BackupAPI?) {
        self.api = api
    }

    func snapshots() -> AsyncStream<SyncSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropContinuation(id) } }
        return stream
    }

    private func dropContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }

    var isRunning: Bool { runTask != nil }

    func start(fullScan: Bool) {
        guard runTask == nil else { return }
        paused = false
        runID += 1
        let id = runID
        let previous = drainingTask
        snapshot.isRunning = true
        snapshot.lastError = nil
        runTask = Task {
            await previous?.value
            await self.run(fullScan: fullScan)
            await self.runEnded(id)
        }
        publish(force: true)
    }

    func pause() {
        paused = true
        stopRun()
        setPhase(.paused)
    }

    /// Stops the pass and discards prepared-but-unfinished uploads (the assets stay queued).
    func cancel() async {
        paused = true
        stopRun()
        await drainingTask?.value
        if let (files, uploads) = try? await store.cancelInFlight() {
            deleteChunkFiles(files)
            if let api {
                for upload in uploads { try? await api.cancelUpload(upload) }
            }
        }
        active.removeAll()
        await refreshCounts()
        setPhase(.idle)
    }

    /// Background-task expiry: stop without marking the engine paused.
    func stopRun() {
        drainingTask = runTask
        runTask?.cancel()
        runTask = nil
        snapshot.isRunning = false
        publish(force: true)
    }

    func waitForRun() async {
        await runTask?.value
    }

    func retryFailed() async {
        _ = try? await store.retryFailed()
        await refreshCounts()
        start(fullScan: false)
    }

    func retry(_ localID: String) async {
        try? await store.retry(localID)
        await refreshCounts()
        start(fullScan: false)
    }

    func enqueueFiles(_ files: [FileImporter.Imported]) async throws {
        for file in files {
            try await store.addFile(localID: file.localID, displayName: file.displayName, stagedName: file.stagedName, size: file.size, createdAt: file.createdAt)
        }
        await refreshCounts()
    }

    func reset() async {
        stopRun()
        await drainingTask?.value
        try? await store.reset()
        for dir in [dirs.exports, dirs.chunks, dirs.staging] {
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        active.removeAll()
        snapshot = SyncSnapshot()
        publish(force: true)
    }

    func refreshCounts() async {
        if let counts = try? await store.counts() { snapshot.counts = counts }
        snapshot.remainingBytes = (try? await store.remainingBytesEstimate()) ?? snapshot.remainingBytes
        snapshot.uploadedBytes = (try? await store.completedBytes()) ?? snapshot.uploadedBytes
        snapshot.openServerSessions = (try? await store.openSessionCount()) ?? snapshot.openServerSessions
        if let waiting = try? await store.waitingRetryCounts() {
            snapshot.waitingRetryAssets = waiting.assets
            snapshot.waitingRetryChunks = waiting.chunks
        }
        publish()
    }

    private func runEnded(_ id: Int) {
        guard id == runID else { return }
        runTask = nil
        snapshot.isRunning = false
        active.removeAll()
        publish(force: true)
    }

    // MARK: - Pass

    private func run(fullScan: Bool) async {
        guard let api else { setPhase(.needsSetup(String(localized: "Set up the server connection first."))); return }
        guard keyVault.isConfigured else { setPhase(.needsSetup(String(localized: "Set up your recovery key first."))); return }
        let settings = await environment.settings()
        do {
            if environment.photosAuthorized() {
                try await scan(full: fullScan, settings: settings)
            }
            try await recover(api: api)
            await refreshCounts()
            adaptive = AdaptiveConcurrency(start: 1, ceiling: max(1, settings.maxConcurrency))
            deferred.removeAll()
            try await process(api: api)
            try Task.checkCancellation()
            await refreshCounts()
            setPhase(.finished(Date()))
        } catch is CancellationError {
            setPhase(paused ? .paused : .idle)
        } catch {
            Log.sync.error("Sync pass failed: \(error.localizedDescription, privacy: .public)")
            snapshot.lastError = error.localizedDescription
            setPhase(.failed(error.localizedDescription))
        }
        await refreshCounts()
    }

    private func kinds(_ settings: SyncSettings) -> Set<ItemKind> {
        var kinds: Set<ItemKind> = [.file]
        if settings.includePhotos { kinds.formUnion([.photo, .livePhoto]) }
        if settings.includeVideos { kinds.insert(.video) }
        return kinds
    }

    private func scan(full: Bool, settings: SyncSettings) async throws {
        setPhase(.scanning(0))
        let kinds = kinds(settings)
        if !full, let token = try await store.metaData("scan.token") {
            do {
                let changes = try scanner.changes(since: token, kinds: kinds)
                let generation = try await store.metaInt("scan.generation") ?? 0
                try await store.upsertScanned(changes.inserted, generation: generation)
                try await store.removeDeleted(changes.deleted)
                try await store.setMetaData("scan.token", changes.token)
                return
            } catch LibraryScanner.ScanError.tokenExpired {
                Log.sync.notice("Photo change token expired; running a full scan")
            }
        }
        let token = scanner.currentToken()
        let generation = try await store.nextGeneration()
        let counter = LockedBox(0)
        _ = try await scanner.fullScan(kinds: kinds) { [weak self] batch in
            try await self?.ingest(batch, generation: generation)
            let total = counter.withValue { value -> Int in value += batch.count; return value }
            await self?.setPhase(.scanning(total))
        }
        try await store.pruneUnseen(generation: generation)
        try await store.setMetaData("scan.token", token)
    }

    private func ingest(_ batch: [ScannedAsset], generation: Int64) async throws {
        try await store.upsertScanned(batch, generation: generation)
    }

    /// After a crash or termination: restart interrupted encryption, and ask the
    /// server which chunks of open uploads already arrived (background uploads
    /// may have finished while the app was not running).
    private func recover(api: BackupAPI) async throws {
        deleteChunkFiles(try await store.resetInterruptedPreparation())
        for object in try await store.objectsNeedingUpload() where object.uploadID != nil {
            try Task.checkCancellation()
            do {
                try await ensureUpload(object, api: api)
            } catch let error as APIError where !error.isRetryable && error.status != 401 {
                Log.sync.notice("Re-preparing asset after server error \(error.code ?? "", privacy: .public)")
                try await requeueReleasingSessions(object.localID, error: error.localizedDescription, retryAfter: nil, countAttempt: true, api: api)
            }
        }
        for localID in try await store.assetsAwaitingFinalization() {
            try await finalize(localID, api: api)
        }
        cleanOrphanFiles()
    }

    private func ensureUpload(_ object: QueueObject, api: BackupAPI) async throws {
        if let uploadID = object.uploadID {
            do {
                let status = try await api.uploadStatus(uploadID)
                if status.status == "active" {
                    for chunk in status.received ?? [] {
                        try await store.markChunkDone(objectID: object.objectID, index: chunk.index)
                    }
                    if try await store.remainingChunks(objectID: object.objectID) == 0 {
                        try await completeObject(object.objectID, api: api)
                    }
                    return
                }
                if status.status == "completed" {
                    try await completeObject(object.objectID, api: api)
                    return
                }
            } catch let error as APIError where error.status == 404 || error.status == 410 {
                // Expired on the server: start a fresh upload of the same encrypted object.
            }
        }
        let session = try await api.createUpload(objectID: object.objectID, sizeBytes: object.cipherSize, chunkSize: object.chunkSize,
                                                 chunkCount: object.chunkCount, sha256: object.cipherSHA256)
        if session.status == "completed" {
            deleteChunkFiles(try await store.markObjectCompleted(object.objectID))
            return
        }
        guard let uploadID = session.uploadId else { throw APIError.invalidResponse }
        try await store.setUploadID(objectID: object.objectID, uploadID: uploadID)
        for chunk in session.received ?? [] {
            try await store.markChunkDone(objectID: object.objectID, index: chunk.index)
        }
    }

    // MARK: - Main loop

    private enum Outcome: Sendable {
        case prepared(String)
        case chunk(QueueChunk, Result<Bool, Error>)
    }

    private func process(api: BackupAPI) async throws {
        var inFlight = Set<String>()
        var preparing = false
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            defer { group.cancelAll() }
            while true {
                try Task.checkCancellation()
                let settings = await environment.settings()
                let conditions = await environment.conditions()
                let decision = TransferPolicy.decide(settings: settings, conditions: conditions)
                adaptive.setCeiling(max(1, decision.concurrency))
                snapshot.concurrency = decision.concurrency
                snapshot.adaptiveLimit = adaptive.limit
                snapshot.blockReason = decision.blockReason
                let busyUntil = api.pressure.blockedUntil()
                snapshot.serverBusyUntil = busyUntil
                snapshot.serverBusyReason = busyUntil == nil ? nil : api.pressure.state.lastReason
                if busyUntil == nil { deferred.removeAll() }
                snapshot.deferredByServer = deferred.count

                if decision.isBlocked && inFlight.isEmpty && !preparing {
                    setPhase(.waiting(decision.blockReason ?? ""))
                    try await waitForConditionsChange(conditions.network)
                    continue
                }
                // Server back-pressure: nothing new is sent until Retry-After has passed.
                if let busyUntil, inFlight.isEmpty, !preparing {
                    setPhase(.waiting(String(localized: "Server is busy — resuming at \(busyUntil.formatted(date: .omitted, time: .standard))")))
                    try await Task.sleep(nanoseconds: UInt64(max(busyUntil.timeIntervalSinceNow, 0.5) * 1_000_000_000))
                    continue
                }
                if snapshot.phase != .running { setPhase(.running) }

                if !preparing, !decision.isBlocked, busyUntil == nil,
                   try await store.pendingChunkBytes() < preparedWindow,
                   try await store.inFlightAssetCount() < maxPreparedAssets,
                   let asset = try await store.nextPendingAsset(kinds: kinds(settings)) {
                    preparing = true
                    try await store.markPreparing(asset.localID)
                    let chunkSize = settings.chunkSize
                    group.addTask { [self] in
                        await self.prepare(asset, api: api, chunkSize: chunkSize)
                        return .prepared(asset.localID)
                    }
                }

                // One global limit for every chunk request of this device: the smaller of
                // what conditions allow and what the server has proven it can take.
                let capacity = busyUntil == nil ? min(decision.concurrency, adaptive.limit) - inFlight.count : 0
                snapshot.activeConnections = inFlight.count
                if capacity > 0 {
                    for chunk in try await store.pendingChunks(limit: capacity, excluding: inFlight) {
                        inFlight.insert(chunk.key)
                        group.addTask { [self] in
                            do {
                                let sent = try await self.upload(chunk, api: api)
                                return .chunk(chunk, .success(sent))
                            } catch {
                                return .chunk(chunk, .failure(error))
                            }
                        }
                    }
                }

                if inFlight.isEmpty && !preparing {
                    let assetRetry = try await store.earliestRetry()
                    let chunkRetry = try await store.earliestChunkRetry()
                    let retries = [assetRetry, chunkRetry].compactMap { $0 }
                    if let next = retries.min(), next.timeIntervalSinceNow < 900 {
                        setPhase(.waiting(String(localized: "Retrying at \(next.formatted(date: .omitted, time: .standard))")))
                        try await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSinceNow, 1) * 1_000_000_000))
                        continue
                    }
                    return
                }

                guard let outcome = try await group.next() else { continue }
                switch outcome {
                case .prepared:
                    preparing = false
                case .chunk(let chunk, let result):
                    inFlight.remove(chunk.key)
                    snapshot.activeConnections = inFlight.count
                    try await handleChunkResult(chunk, result: result, api: api)
                }
                await refreshCounts()
            }
        }
    }

    private func waitForConditionsChange(_ network: NetworkStatus) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [monitor = self.network] in try await monitor.waitForChange(from: network) }
            group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000) }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Preparation (export + encrypt + register uploads)

    private nonisolated func prepare(_ asset: QueueAsset, api: BackupAPI, chunkSize: Int) async {
        var exportedURLs: [URL] = []
        var producedChunks: [PreparedChunk] = []
        defer { exportedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let keys = try keyVault.keys()
            await track(asset.localID, name: asset.displayName ?? asset.kind.title, stage: .exporting)

            let exported: ExportedAsset
            switch asset.source {
            case .photos:
                exported = try await ResourceExporter(directory: dirs.exports).export(localID: asset.localID, storage: storage)
                exportedURLs = exported.resources.map(\.fileURL)
            case .files:
                guard let staged = asset.stagedName else { throw ExportError.noOriginal }
                let url = dirs.staging.appendingPathComponent(staged)
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let name = asset.displayName ?? staged
                let uti = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
                exported = ExportedAsset(kind: .file, resources: [ExportedResource(role: .file, fileURL: url, filename: name, uti: uti, size: size)],
                                         createdAt: asset.createdAt, modifiedAt: nil, pixelWidth: 0, pixelHeight: 0, duration: nil, isFavorite: false)
            }

            try storage.ensure(exported.totalSize + Int64(chunkSize))
            let displayName = exported.primary?.filename ?? asset.displayName
            await track(asset.localID, name: displayName ?? asset.kind.title, stage: .encrypting, total: exported.totalSize)

            var objects: [(QueueObject, [PreparedChunk])] = []
            var resources: [ItemManifest.Resource] = []
            for resource in exported.resources {
                try Task.checkCancellation()
                let objectID = WZCE.randomBytes(16)
                let prepared = try ChunkPreparer.encrypt(file: resource.fileURL, objectID: objectID, kek: keys.fileWrap,
                                                         segmentSize: WZCE.defaultSegmentSize, chunkSize: chunkSize, into: dirs.chunks)
                producedChunks += prepared.chunks
                objects.append((Self.queueObject(prepared, localID: asset.localID, role: resource.role, filename: resource.filename, uti: resource.uti), prepared.chunks))
                resources.append(.init(role: resource.role, objectId: prepared.objectID, filename: resource.filename, uti: resource.uti,
                                       size: prepared.plainSize, sha256: prepared.plainSHA256))
            }
            if let thumbnail = await Self.thumbnail(for: exported) {
                let prepared = try ChunkPreparer.encrypt(data: thumbnail, objectID: WZCE.randomBytes(16), kek: keys.fileWrap, chunkSize: chunkSize, into: dirs.chunks)
                producedChunks += prepared.chunks
                objects.append((Self.queueObject(prepared, localID: asset.localID, role: .thumbnail, filename: "thumbnail.jpg", uti: UTType.jpeg.identifier), prepared.chunks))
                resources.append(.init(role: .thumbnail, objectId: prepared.objectID, filename: "thumbnail.jpg", uti: UTType.jpeg.identifier,
                                       size: prepared.plainSize, sha256: prepared.plainSHA256))
            }

            let manifest = ItemManifest(kind: exported.kind, source: asset.source.rawValue, originalFilename: exported.primary?.filename,
                                        createdAt: exported.createdAt, modifiedAt: exported.modifiedAt,
                                        pixelWidth: exported.pixelWidth > 0 ? exported.pixelWidth : nil,
                                        pixelHeight: exported.pixelHeight > 0 ? exported.pixelHeight : nil,
                                        duration: exported.duration, isFavorite: exported.isFavorite, resources: resources)
            let tag = manifest.contentTag(keys: keys)

            // Duplicate prevention: identical content already queued/backed up locally, or on the server.
            var duplicate = try await store.isTagCompleted(tag, excluding: asset.localID)
            if !duplicate { duplicate = try await api.existingTags([tag])[tag] != nil }
            if duplicate {
                Self.deleteFiles(producedChunks.map(\.url))
                producedChunks = []
                await finishDuplicate(asset.localID)
                return
            }

            // No server session is opened here. Sessions are opened lazily, one object at a
            // time, when its first chunk is about to be sent (see `session(for:api:)`), so
            // encrypting ahead never ties up server resources.
            await track(asset.localID, name: displayName ?? asset.kind.title, stage: .uploading, total: exported.totalSize)
            let itemID = WZCE.randomBytes(16)
            let item = PreparedItem(localID: asset.localID, itemID: itemID.hexString, kind: exported.kind,
                                    manifest: try manifest.sealed(itemID: itemID, keys: keys), contentTag: tag, objectIDs: objects.map(\.0.objectID))
            try await store.savePrepared(item, displayName: displayName, totalBytes: exported.totalSize, objects: objects)
        } catch {
            Self.deleteFiles(producedChunks.map(\.url))
            await prepareFailed(asset.localID, error: error)
        }
    }

    private static func queueObject(_ prepared: PreparedObject, localID: String, role: ResourceRole, filename: String, uti: String?) -> QueueObject {
        QueueObject(objectID: prepared.objectID, localID: localID, role: role, filename: filename, uti: uti, plainSize: prepared.plainSize,
                    plainSHA256: prepared.plainSHA256, cipherSize: prepared.cipherSize, cipherSHA256: prepared.cipherSHA256,
                    chunkSize: prepared.chunkSize, chunkCount: prepared.chunks.count, uploadID: nil, completed: false)
    }

    static func thumbnail(for exported: ExportedAsset) async -> Data? {
        guard let primary = exported.primary else { return nil }
        let type = primary.uti.flatMap(UTType.init) ?? UTType(filenameExtension: (primary.filename as NSString).pathExtension)
        if exported.kind == .video || type?.conforms(to: .movie) == true {
            return await VideoThumbnailGenerator.jpegThumbnail(for: AVURLAsset(url: primary.fileURL), maxPixelSize: 400)
        }
        if type?.conforms(to: .image) == true || exported.kind == .photo || exported.kind == .livePhoto {
            return ImageDownsampler.jpegThumbnail(fileURL: primary.fileURL, maxPixelSize: 400)
        }
        return nil
    }

    private func prepareFailed(_ localID: String, error: Error) async {
        active.removeValue(forKey: localID)
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        do {
            if error is CancellationError {
                deleteChunkFiles(try await store.requeue(localID, error: nil, retryAfter: nil, countAttempt: false))
            } else if case StorageError.lowStorage = error {
                deleteChunkFiles(try await store.requeue(localID, error: message, retryAfter: Date().addingTimeInterval(600), countAttempt: false))
                snapshot.lastError = message
            } else if let apiError = error as? APIError, let status = apiError.status, ServerPressure.isPressure(status: status) {
                let until = api?.pressure.blockedUntil() ?? Date().addingTimeInterval(Backoff(base: 5, maximum: 300).delay(forAttempt: 1))
                deleteChunkFiles(try await store.requeue(localID, error: message, retryAfter: until, countAttempt: false))
            } else if let export = error as? ExportError, export == .assetNotFound || export == .noOriginal {
                deleteChunkFiles(try await store.markFailed(localID, error: message))
            } else if Self.isRetryable(error) {
                let attempts = try await store.attempts(localID) + 1
                if attempts >= AppConfig.maxAttempts {
                    deleteChunkFiles(try await store.markFailed(localID, error: message))
                } else {
                    deleteChunkFiles(try await store.requeue(localID, error: message, retryAfter: Date().addingTimeInterval(Backoff().delay(forAttempt: attempts)), countAttempt: true))
                }
            } else {
                deleteChunkFiles(try await store.markFailed(localID, error: message))
            }
        } catch {
            Log.sync.error("Could not record failure: \(error.localizedDescription, privacy: .public)")
        }
        if !(error is CancellationError) {
            Log.sync.notice("Preparing an item failed: \(message, privacy: .public)")
        }
        publish()
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let api = error as? APIError { return api.isRetryable || api.status == 401 }
        if let export = error as? ExportError, case .iCloudFailed = export { return true }
        if error is URLError { return true }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain || ns.domain == NSCocoaErrorDomain
    }

    private func finishDuplicate(_ localID: String) async {
        active.removeValue(forKey: localID)
        if let staged = try? await store.markFinished(localID, duplicate: true) {
            try? FileManager.default.removeItem(at: dirs.staging.appendingPathComponent(staged))
        }
        publish()
    }

    // MARK: - Chunk upload

    /// Returns true when bytes were sent, false when nothing had to be sent (the server
    /// already had the chunk or the whole object).
    private nonisolated func upload(_ chunk: QueueChunk, api: BackupAPI) async throws -> Bool {
        let fileURL = dirs.chunks.appendingPathComponent(chunk.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ChunkFileMissing() }
        let resolved: String?
        if let existing = chunk.uploadID { resolved = existing } else { resolved = try await session(for: chunk, api: api) }
        guard let uploadID = resolved else { return false }
        var (response, body) = try await transport.upload(
            try api.chunkRequest(uploadID: uploadID, index: chunk.index, sha256: chunk.sha256, token: try await api.bearerToken()), fromFile: fileURL)
        if response.statusCode == 401 {
            if api.configuration.authMethod == .password { try await api.login() }
            (response, body) = try await transport.upload(
                try api.chunkRequest(uploadID: uploadID, index: chunk.index, sha256: chunk.sha256, token: try await api.bearerToken()), fromFile: fileURL)
        }
        api.observe(response, data: body)
        guard (200..<300).contains(response.statusCode) else { throw APIError.from(status: response.statusCode, data: body) }
        return true
    }

    /// Opens (or resumes) the server session for a chunk's object right before its
    /// first chunk is sent. Idempotent: the server returns the same session for the
    /// same object, so two chunks of one object racing here cannot open two sessions.
    /// Returns nil when nothing needs to be sent for this chunk.
    private func session(for chunk: QueueChunk, api: BackupAPI) async throws -> String? {
        guard let object = try await store.object(chunk.objectID), !object.completed else { return nil }
        if let uploadID = object.uploadID { return uploadID }
        try await ensureUpload(object, api: api)
        guard let refreshed = try await store.object(chunk.objectID), !refreshed.completed,
              !(try await store.isChunkDone(objectID: chunk.objectID, index: chunk.index)) else { return nil }
        snapshot.openServerSessions = (try? await store.openSessionCount()) ?? snapshot.openServerSessions
        return refreshed.uploadID
    }

    /// Cancels server sessions of an asset that is being re-prepared or has failed,
    /// so abandoned sessions never accumulate on the server. Best effort.
    private func releaseServerSessions(_ uploadIDs: [String], api: BackupAPI) {
        guard !uploadIDs.isEmpty else { return }
        Task.detached(priority: .utility) {
            for uploadID in uploadIDs { try? await api.cancelUpload(uploadID) }
        }
    }

    private func requeueReleasingSessions(_ localID: String, error: String?, retryAfter: Date?, countAttempt: Bool, api: BackupAPI) async throws {
        let sessions = (try? await store.openUploadIDs(localID: localID)) ?? []
        deleteChunkFiles(try await store.requeue(localID, error: error, retryAfter: retryAfter, countAttempt: countAttempt))
        releaseServerSessions(sessions, api: api)
    }

    private func failReleasingSessions(_ localID: String, error: String, api: BackupAPI) async throws {
        let sessions = (try? await store.openUploadIDs(localID: localID)) ?? []
        deleteChunkFiles(try await store.markFailed(localID, error: error))
        releaseServerSessions(sessions, api: api)
    }

    struct ChunkFileMissing: Error, LocalizedError {
        var errorDescription: String? { String(localized: "A prepared upload file is missing; the item will be encrypted again.") }
    }

    private func handleChunkResult(_ chunk: QueueChunk, result: Result<Bool, Error>, api: BackupAPI) async throws {
        guard let object = try await store.object(chunk.objectID) else { return }
        switch result {
        case .success(let sent):
            deferred.remove(chunk.key)
            try await store.markChunkDone(objectID: chunk.objectID, index: chunk.index)
            if sent {
                adaptive.success()
                meter.add(Int64(chunk.size))
                snapshot.sessionBytes += Int64(chunk.size)
            }
            if var transfer = active[object.localID] {
                transfer.sentBytes += Int64(chunk.size)
                transfer.stage = .uploading
                active[object.localID] = transfer
            } else {
                let asset = try await store.asset(object.localID)
                active[object.localID] = ActiveTransfer(id: object.localID, name: asset?.displayName ?? object.filename, stage: .uploading,
                                                        sentBytes: Int64(chunk.size), totalBytes: asset?.totalBytes ?? object.cipherSize)
            }
            publish()
            if try await store.remainingChunks(objectID: chunk.objectID) == 0 {
                try await completeObject(chunk.objectID, api: api)
                if try await store.remainingObjects(localID: object.localID) == 0 {
                    try await finalize(object.localID, api: api)
                }
            }
        case .failure(let error):
            if error is CancellationError { throw error }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let apiError = error as? APIError
            let corrupt = error is ChunkFileMissing || ["checksum_mismatch", "chunk_conflict", "chunk_size_mismatch", "chunk_truncated"].contains(apiError?.code ?? "")
            if let status = apiError?.status, ServerPressure.isPressure(status: status) {
                // Back-pressure is not a failure of this chunk: halve parallelism, wait
                // for Retry-After (the gate is shared by every request), keep attempts.
                adaptive.pressure()
                let until = api.pressure.blockedUntil() ?? Date().addingTimeInterval(Backoff(base: 2, maximum: 300).delay(forAttempt: 1))
                try await store.deferChunk(objectID: chunk.objectID, index: chunk.index, until: until)
                deferred.insert(chunk.key)
                Log.sync.notice("Server busy (HTTP \(status, privacy: .public)); waiting \(Int(max(until.timeIntervalSinceNow, 0)), privacy: .public) s")
            } else if corrupt || apiError?.status == 410 || apiError?.status == 404 {
                Log.sync.notice("Re-preparing item after chunk error: \(message, privacy: .public)")
                active.removeValue(forKey: object.localID)
                try await requeueReleasingSessions(object.localID, error: message, retryAfter: nil, countAttempt: true, api: api)
            } else if Self.isRetryable(error) {
                adaptive.failure()
                let attempts = try await store.markChunkRetry(objectID: chunk.objectID, index: chunk.index,
                                                              retryAfter: Date().addingTimeInterval(Backoff(base: 2, maximum: 300).delay(forAttempt: chunk.attempts + 1)))
                try await store.noteError(object.localID, message)
                if attempts >= AppConfig.maxAttempts * 2 {
                    active.removeValue(forKey: object.localID)
                    try await failReleasingSessions(object.localID, error: message, api: api)
                }
            } else {
                active.removeValue(forKey: object.localID)
                try await failReleasingSessions(object.localID, error: message, api: api)
            }
            snapshot.lastError = message
        }
        snapshot.adaptiveLimit = adaptive.limit
        snapshot.deferredByServer = deferred.count
    }

    /// Asks the server to assemble the object and verify its SHA-256; only then is it considered stored.
    private func completeObject(_ objectID: String, api: BackupAPI) async throws {
        guard let object = try await store.object(objectID), !object.completed, let uploadID = object.uploadID else { return }
        if var transfer = active[object.localID] { transfer.stage = .verifying; active[object.localID] = transfer; publish() }
        do {
            let completed = try await api.completeUpload(uploadID)
            guard completed.sha256 == object.cipherSHA256, completed.sizeBytes == object.cipherSize else {
                throw APIError.server(status: 422, code: "object_hash_mismatch", message: String(localized: "Server copy does not match the encrypted file."), missing: nil, itemID: nil)
            }
            deleteChunkFiles(try await store.markObjectCompleted(objectID))
        } catch let error as APIError where error.code == "upload_completed" {
            deleteChunkFiles(try await store.markObjectCompleted(objectID))
        } catch let error as APIError where error.code == "upload_incomplete" {
            Log.sync.notice("Server reported missing chunks; re-sending them")
            try await store.reopenChunks(objectID: objectID, indices: error.missingIndices)
        } catch let error as APIError where error.code == "object_hash_mismatch" || error.status == 410 {
            active.removeValue(forKey: object.localID)
            try await requeueReleasingSessions(object.localID, error: error.localizedDescription, retryAfter: nil, countAttempt: true, api: api)
        }
    }

    private func finalize(_ localID: String, api: BackupAPI) async throws {
        guard let item = try await store.preparedItem(localID: localID) else { return }
        try await store.setState(localID, .finalizing)
        do {
            let result = try await api.createItem(itemID: item.itemID, contentTag: item.contentTag, kind: item.kind, manifest: item.manifest, objectIDs: item.objectIDs)
            let duplicate: Bool
            if case .duplicate = result { duplicate = true } else { duplicate = false }
            if let staged = try await store.markFinished(localID, duplicate: duplicate) {
                try? FileManager.default.removeItem(at: dirs.staging.appendingPathComponent(staged))
            }
            active.removeValue(forKey: localID)
            publish()
        } catch let error as APIError where error.isRetryable || error.status == 401 {
            try await store.setState(localID, .uploading)
            throw error
        }
    }

    // MARK: - Files & progress

    private nonisolated func deleteChunkFiles(_ names: [String]) {
        Self.deleteFiles(names.map { dirs.chunks.appendingPathComponent($0) })
    }

    private static func deleteFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Removes chunk/staging files no longer referenced by the queue (e.g. after a crash).
    private func cleanOrphanFiles() {
        Task {
            let chunks = (try? await store.referencedChunkNames()) ?? []
            let staged = (try? await store.referencedStagedNames()) ?? []
            for file in (try? FileManager.default.contentsOfDirectory(at: dirs.chunks, includingPropertiesForKeys: nil)) ?? [] where !chunks.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
            for file in (try? FileManager.default.contentsOfDirectory(at: dirs.staging, includingPropertiesForKeys: nil)) ?? [] where !staged.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func track(_ localID: String, name: String, stage: ActiveTransfer.Stage, total: Int64? = nil) {
        var transfer = active[localID] ?? ActiveTransfer(id: localID, name: name, stage: stage)
        transfer.name = name
        transfer.stage = stage
        if let total { transfer.totalBytes = total }
        active[localID] = transfer
        publish()
    }

    private func setPhase(_ phase: SyncPhase) {
        guard snapshot.phase != phase else { return }
        snapshot.phase = phase
        publish(force: true)
    }

    private func publish(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < 0.3 {
            if !publishPending {
                publishPending = true
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await self.flush()
                }
            }
            return
        }
        lastPublish = now
        publishPending = false
        snapshot.active = active.values.sorted { $0.id < $1.id }
        snapshot.bytesPerSecond = meter.rate(now: now)
        snapshot.averageBytesPerSecond = meter.averageRate(now: now)
        snapshot.etaSeconds = TransferEstimate.eta(remainingBytes: snapshot.remainingBytes, averageBytesPerSecond: snapshot.averageBytesPerSecond)
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func flush() {
        if publishPending { publish(force: true) }
    }
}

extension APIError {
    var missingIndices: [Int] {
        if case .server(_, _, _, let missing?, _) = self { return missing }
        return []
    }
}

extension URL {
    func createdDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = self
        try? copy.setResourceValues(values)
        return self
    }
}
