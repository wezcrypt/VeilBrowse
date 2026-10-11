import XCTest
@testable import WezCryptSecureStudio

final class SyncStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SyncStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SyncStore(path: directory.appendingPathComponent("sync.sqlite3").path)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func assets(_ count: Int, kind: MediaKind = .photo, prefix: String = "asset") -> [ScannedAsset] {
        (0..<count).map { ScannedAsset(localIdentifier: "\(prefix)-\($0)", kind: kind, creationDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + $0))) }
    }

    func testScanQueueAndComplete() async throws {
        let generation = try await store.nextGeneration()
        let inserted = try await store.upsertScanned(assets(5) + assets(2, kind: .video, prefix: "video"), generation: generation)
        XCTAssertEqual(inserted, 7)
        let again = try await store.upsertScanned(assets(5), generation: generation)
        XCTAssertEqual(again, 0)

        let counts = try await store.counts()
        XCTAssertEqual(counts.pending, 7)

        let photosOnly = try await store.nextPending(limit: 10, kinds: [.photo], excluding: [])
        XCTAssertEqual(photosOnly.count, 5)
        XCTAssertEqual(photosOnly.first?.localID, "asset-4", "newest first")

        let excluding = try await store.nextPending(limit: 3, kinds: [.photo, .video], excluding: ["asset-4"])
        XCTAssertFalse(excluding.contains { $0.localID == "asset-4" })
        XCTAssertEqual(excluding.count, 3)

        try await store.markUploading("asset-4")
        try await store.updateFileInfo("asset-4", sha256: "abc", bytes: 1234, filename: "IMG.HEIC")
        try await store.markCompleted("asset-4", remoteMediaID: "remote-1")
        let record = try await store.record("asset-4")
        XCTAssertEqual(record?.state, .completed)
        XCTAssertEqual(record?.remoteMediaID, "remote-1")
        XCTAssertEqual(record?.bytes, 1234)
        let completedIDs = try await store.completedLocalIDs()
        XCTAssertEqual(completedIDs, ["asset-4"])
        let average = try await store.averageCompletedBytes()
        XCTAssertEqual(average, 1234)
    }

    func testRetryBackoffAndFailure() async throws {
        let generation = try await store.nextGeneration()
        try await store.upsertScanned(assets(1), generation: generation)
        try await store.markPending("asset-0", error: "timeout", retryAfter: Date().addingTimeInterval(600), countAttempt: true)
        let delayed = try await store.nextPending(limit: 5, kinds: [.photo], excluding: [])
        XCTAssertTrue(delayed.isEmpty, "items in backoff are not handed out")
        let retryDate = try await store.earliestRetryDate(kinds: [.photo])
        XCTAssertNotNil(retryDate)

        try await store.markFailed("asset-0", error: "bad")
        var counts = try await store.counts()
        XCTAssertEqual(counts.failed, 1)
        let failed = try await store.records(state: .failed, limit: 10, offset: 0)
        XCTAssertEqual(failed.first?.attempts, 2)
        XCTAssertEqual(failed.first?.lastError, "bad")

        let retried = try await store.retryAllFailed()
        XCTAssertEqual(retried, 1)
        counts = try await store.counts()
        XCTAssertEqual(counts.pending, 1)
        let ready = try await store.nextPending(limit: 5, kinds: [.photo], excluding: [])
        XCTAssertEqual(ready.count, 1)
    }

    func testPruneKeepsCompletedItems() async throws {
        let first = try await store.nextGeneration()
        try await store.upsertScanned(assets(3), generation: first)
        try await store.markCompleted("asset-0", remoteMediaID: "r")
        let second = try await store.nextGeneration()
        try await store.upsertScanned([assets(3)[1]], generation: second)
        try await store.pruneUnseen(generation: second)
        let counts = try await store.counts()
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.pending, 1)
        let missing = try await store.record("asset-2")
        XCTAssertNil(missing)
    }

    func testStaleUploadingResetAndMeta() async throws {
        let generation = try await store.nextGeneration()
        try await store.upsertScanned(assets(2), generation: generation)
        try await store.markUploading("asset-1")
        try await store.resetStaleUploading()
        let counts = try await store.counts()
        XCTAssertEqual(counts.uploading, 0)
        XCTAssertEqual(counts.pending, 2)

        try await store.setMetaData("scan.token", Data([1, 2, 3]))
        let token = try await store.metaData("scan.token")
        XCTAssertEqual(token, Data([1, 2, 3]))
        try await store.setMetaData("scan.token", nil)
        let cleared = try await store.metaData("scan.token")
        XCTAssertNil(cleared)

        try await store.reset()
        let afterReset = try await store.counts()
        XCTAssertEqual(afterReset.total, 0)
    }

    func testLargeBatchPerformance() async throws {
        let generation = try await store.nextGeneration()
        let batch = assets(20_000)
        let start = Date()
        try await store.upsertScanned(batch, generation: generation)
        let elapsed = Date().timeIntervalSince(start)
        let counts = try await store.counts()
        XCTAssertEqual(counts.pending, 20_000)
        XCTAssertLessThan(elapsed, 30, "20k inserts should be fast inside one transaction")
    }
}
