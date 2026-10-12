import XCTest
@testable import WezCryptSecureStudio

final class QueueStoreTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func scanned(_ n: Int) -> [ScannedAsset] {
        (0..<n).map { ScannedAsset(localID: "asset-\($0)", kind: $0 % 3 == 0 ? .video : .photo, createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + $0))) }
    }

    private func object(_ id: String, localID: String, chunks: Int) -> (QueueObject, [PreparedChunk]) {
        let object = QueueObject(objectID: id, localID: localID, role: .photo, filename: "IMG.HEIC", uti: nil, plainSize: 10, plainSHA256: "p",
                                 cipherSize: Int64(chunks * 4), cipherSHA256: "c", chunkSize: 4, chunkCount: chunks, uploadID: "u-\(id)", completed: false)
        let parts = (0..<chunks).map { PreparedChunk(index: $0, url: URL(fileURLWithPath: "/tmp/\(id).\($0).chunk"), size: 4, sha256: "s\($0)") }
        return (object, parts)
    }

    func testQueueSurvivesRelaunch() async throws {
        do {
            let store = try QueueStore(path: path)
            let generation = try await store.nextGeneration()
            let inserted = try await store.upsertScanned(scanned(6), generation: generation)
            XCTAssertEqual(inserted, 6)
            let again = try await store.upsertScanned(scanned(6), generation: generation)
            XCTAssertEqual(again, 0, "re-scanning must not duplicate queue entries")
            try await store.markPreparing("asset-5")
            try await store.savePrepared(PreparedItem(localID: "asset-5", itemID: "i5", kind: .photo, manifest: Data([1]), contentTag: "t5", objectIDs: ["o5"]),
                                         displayName: "IMG_5.HEIC", totalBytes: 10, objects: [object("o5", localID: "asset-5", chunks: 3)])
            try await store.markChunkDone(objectID: "o5", index: 0)
            try await store.markPreparing("asset-4")
        }
        // Simulated app relaunch: a new store on the same file.
        let store = try QueueStore(path: path)
        let interrupted = try await store.resetInterruptedPreparation()
        XCTAssertTrue(interrupted.isEmpty)
        let counts = try await store.counts()
        XCTAssertEqual(counts.active, 1)
        XCTAssertEqual(counts.pending, 5)
        let pending = try await store.pendingChunks(limit: 10, excluding: [])
        XCTAssertEqual(pending.map(\.index), [1, 2], "already uploaded chunks are not sent again")
        XCTAssertEqual(pending.first?.uploadID, "u-o5")
    }

    func testCompletionFlowAndDuplicateTags() async throws {
        let store = try QueueStore(path: path)
        try await store.upsertScanned(scanned(2), generation: try await store.nextGeneration())
        try await store.markPreparing("asset-1")
        try await store.savePrepared(PreparedItem(localID: "asset-1", itemID: "i1", kind: .photo, manifest: Data([1]), contentTag: "tag", objectIDs: ["o1"]),
                                     displayName: nil, totalBytes: 8, objects: [object("o1", localID: "asset-1", chunks: 2)])
        for index in 0..<2 { try await store.markChunkDone(objectID: "o1", index: index) }
        let remainingChunks = try await store.remainingChunks(objectID: "o1")
        XCTAssertEqual(remainingChunks, 0)
        let names = try await store.markObjectCompleted("o1")
        XCTAssertEqual(names.count, 2)
        let remainingObjects = try await store.remainingObjects(localID: "asset-1")
        XCTAssertEqual(remainingObjects, 0)
        let ready = try await store.assetsAwaitingFinalization()
        XCTAssertEqual(ready, ["asset-1"])
        let item = try await store.preparedItem(localID: "asset-1")
        XCTAssertEqual(item?.contentTag, "tag")
        _ = try await store.markFinished("asset-1", duplicate: false)
        let duplicate = try await store.isTagCompleted("tag", excluding: "asset-0")
        XCTAssertTrue(duplicate, "backed-up items keep their content tag for local duplicate prevention")
        let completed = try await store.completedLocalIDs()
        XCTAssertEqual(completed, ["asset-1"])
    }

    func testRetryFailureAndCancel() async throws {
        let store = try QueueStore(path: path)
        try await store.upsertScanned(scanned(3), generation: try await store.nextGeneration())
        _ = try await store.requeue("asset-0", error: "timeout", retryAfter: Date().addingTimeInterval(600), countAttempt: true)
        let next = try await store.nextPendingAsset(kinds: [.photo, .video])
        XCTAssertNotEqual(next?.localID, "asset-0", "assets in backoff are skipped")
        _ = try await store.markFailed("asset-1", error: "boom")
        var counts = try await store.counts()
        XCTAssertEqual(counts.failed, 1)
        try await store.retryFailed()
        counts = try await store.counts()
        XCTAssertEqual(counts.failed, 0)

        try await store.markPreparing("asset-2")
        try await store.savePrepared(PreparedItem(localID: "asset-2", itemID: "i2", kind: .video, manifest: Data([1]), contentTag: "t2", objectIDs: ["o2"]),
                                     displayName: nil, totalBytes: 8, objects: [object("o2", localID: "asset-2", chunks: 2)])
        let cancelled = try await store.cancelInFlight()
        XCTAssertEqual(cancelled.files.count, 2)
        XCTAssertEqual(cancelled.uploads, ["u-o2"])
        counts = try await store.counts()
        XCTAssertEqual(counts.active, 0)
    }

    func testLazySessionsDeferralAndOpenSessionTracking() async throws {
        let store = try QueueStore(path: path)
        try await store.upsertScanned(scanned(2), generation: try await store.nextGeneration())
        var withoutSession = object("o0", localID: "asset-0", chunks: 2)
        withoutSession.0.uploadID = nil
        try await store.markPreparing("asset-0")
        try await store.savePrepared(PreparedItem(localID: "asset-0", itemID: "i0", kind: .video, manifest: Data([1]), contentTag: "t0", objectIDs: ["o0"]),
                                     displayName: nil, totalBytes: 8, objects: [withoutSession])
        try await store.markPreparing("asset-1")
        try await store.savePrepared(PreparedItem(localID: "asset-1", itemID: "i1", kind: .photo, manifest: Data([1]), contentTag: "t1", objectIDs: ["o1"]),
                                     displayName: nil, totalBytes: 8, objects: [object("o1", localID: "asset-1", chunks: 1)])
        // Chunks without a server session are eligible (the session opens lazily), but
        // objects that already have one are finished first.
        let pending = try await store.pendingChunks(limit: 10, excluding: [])
        XCTAssertEqual(pending.map(\.objectID), ["o1", "o0", "o0"])
        XCTAssertNil(pending[1].uploadID)
        let open = try await store.openSessionCount()
        XCTAssertEqual(open, 1)
        let ids = try await store.openUploadIDs(localID: "asset-1")
        XCTAssertEqual(ids, ["u-o1"])
        // Back-pressure deferral postpones without counting an attempt.
        try await store.deferChunk(objectID: "o1", index: 0, until: Date().addingTimeInterval(60))
        let afterDefer = try await store.pendingChunks(limit: 10, excluding: [])
        XCTAssertEqual(afterDefer.map(\.objectID), ["o0", "o0"])
        let waiting = try await store.waitingRetryCounts()
        XCTAssertEqual(waiting.chunks, 1)
        let deferredAttempts = try await store.markChunkRetry(objectID: "o1", index: 0, retryAfter: Date().addingTimeInterval(60))
        XCTAssertEqual(deferredAttempts, 1, "the deferral itself did not count as an attempt")
        let inFlight = try await store.inFlightAssetCount()
        XCTAssertEqual(inFlight, 2)
    }

    func testRemainingBytesEstimateUsesMeasuredAverages() async throws {
        let store = try QueueStore(path: path)
        try await store.upsertScanned((0..<4).map { ScannedAsset(localID: "p\($0)", kind: .photo, createdAt: Date()) }, generation: try await store.nextGeneration())
        // Two photos measured (10 MB and 20 MB) and backed up, two not read yet.
        for (id, size) in [("p0", Int64(10_000_000)), ("p1", Int64(20_000_000))] {
            try await store.markPreparing(id)
            try await store.savePrepared(PreparedItem(localID: id, itemID: "i\(id)", kind: .photo, manifest: Data([1]), contentTag: "t\(id)", objectIDs: ["o\(id)"]),
                                         displayName: nil, totalBytes: size, objects: [object("o\(id)", localID: id, chunks: 1)])
            _ = try await store.markFinished(id, duplicate: false)
        }
        let remaining = try await store.remainingBytesEstimate()
        XCTAssertEqual(remaining, 30_000_000, "two unread photos × 15 MB average")
        let uploaded = try await store.completedBytes()
        XCTAssertEqual(uploaded, 30_000_000)
    }

    func testPruneKeepsBackedUpItems() async throws {
        let store = try QueueStore(path: path)
        let first = try await store.nextGeneration()
        try await store.upsertScanned(scanned(3), generation: first)
        _ = try await store.markFinished("asset-0", duplicate: false)
        let second = try await store.nextGeneration()
        try await store.upsertScanned([scanned(3)[1]], generation: second)
        try await store.pruneUnseen(generation: second)
        let counts = try await store.counts()
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.pending, 1)
    }

    func testLargeLibraryScanPerformance() async throws {
        let store = try QueueStore(path: path)
        let start = Date()
        try await store.upsertScanned(scanned(20_000), generation: try await store.nextGeneration())
        print("[benchmark] queued 20,000 assets in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        let counts = try await store.counts()
        XCTAssertEqual(counts.pending, 20_000)
    }
}

final class TransferPolicyTests: XCTestCase {
    let wifi = NetworkStatus(isConnected: true, isWiFi: true)
    let cellular = NetworkStatus(isConnected: true, isWiFi: false, isCellular: true, isExpensive: true)

    func testNetworkSwitching() {
        var settings = SyncSettings()
        var conditions = DeviceConditions(network: wifi, isCharging: true)
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 4)
        conditions.network = cellular
        XCTAssertTrue(TransferPolicy.decide(settings: settings, conditions: conditions).isBlocked, "Wi‑Fi only blocks cellular")
        settings.wifiOnly = false
        settings.allowCellular = true
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 2, "cellular is throttled")
        conditions.network = NetworkStatus()
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).blockReason, String(localized: "Waiting for a network connection"))
        conditions.network = NetworkStatus(isConnected: true, isWiFi: true, isConstrained: true)
        XCTAssertTrue(TransferPolicy.decide(settings: settings, conditions: conditions).isBlocked, "Low Data Mode respected")
    }

    func testThermalBatteryAndCharging() {
        var settings = SyncSettings()
        var conditions = DeviceConditions(network: wifi, isCharging: true)
        conditions.thermal = .fair
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 2)
        conditions.thermal = .serious
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 1)
        conditions.thermal = .critical
        XCTAssertTrue(TransferPolicy.decide(settings: settings, conditions: conditions).isBlocked)
        conditions.thermal = .nominal
        conditions.isCharging = false
        conditions.batteryLevel = 0.1
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 1)
        conditions.batteryLevel = 0.8
        conditions.lowPowerMode = true
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 1)
        settings.lowPowerBehavior = .pause
        XCTAssertTrue(TransferPolicy.decide(settings: settings, conditions: conditions).isBlocked)
        settings.chargingOnly = true
        conditions.lowPowerMode = false
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).blockReason, String(localized: "Waiting for the charger"))
        settings.maxConcurrency = 50
        conditions.isCharging = true
        XCTAssertEqual(TransferPolicy.decide(settings: settings, conditions: conditions).concurrency, 8, "concurrency is capped")
    }

    func testServerConfigurationValidation() throws {
        XCTAssertEqual(try ServerConfiguration.normalizedURL(" https://studio.rextv.sbs/ ").absoluteString, "https://studio.rextv.sbs")
        XCTAssertThrowsError(try ServerConfiguration.normalizedURL("http://studio.rextv.sbs"))
        XCTAssertThrowsError(try ServerConfiguration.normalizedURL("ftp://x"))
        XCTAssertThrowsError(try ServerConfiguration.normalizedURL("https://studio.rextv.sbs/some/path"))
        let config = ServerConfiguration(serverURL: URL(string: "https://studio.rextv.sbs")!, authMethod: .password, username: "alice", collection: "iphone-backups")
        XCTAssertNoThrow(try config.validate(secret: "pw"))
        XCTAssertThrowsError(try config.validate(secret: ""))
        var bad = config
        bad.collection = "../etc"
        XCTAssertThrowsError(try bad.validate(secret: "pw"))
        bad = config
        bad.username = "Bad User"
        XCTAssertThrowsError(try bad.validate(secret: "pw"))

        XCTAssertEqual(try ServerConfiguration.normalizedURL("https://studio.rextv.sbs:8443").port, 8443)
        XCTAssertEqual(config.requestTimeout, 60)
        bad = config
        bad.timeoutSeconds = 5
        XCTAssertThrowsError(try bad.validate(secret: "pw"))
        bad.timeoutSeconds = 120
        XCTAssertNoThrow(try bad.validate(secret: "pw"))
        XCTAssertEqual(bad.requestTimeout, 120)
        // Configurations saved before the timeout field existed still decode.
        let legacy = Data(#"{"serverURL":"https://studio.rextv.sbs","transport":"https","authMethod":"password","username":"alice","collection":"iphone-backups"}"#.utf8)
        let decoded = try JSONDecoder().decode(ServerConfiguration.self, from: legacy)
        XCTAssertNil(decoded.timeoutSeconds)
        XCTAssertEqual(decoded.requestTimeout, 60)
    }

    func testBackoff() {
        let backoff = Backoff(base: 2, maximum: 60)
        XCTAssertEqual(backoff.delay(forAttempt: 1, jitter: 1), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 4, jitter: 1), 16)
        XCTAssertEqual(backoff.delay(forAttempt: 30, jitter: 1), 60)
    }
}
