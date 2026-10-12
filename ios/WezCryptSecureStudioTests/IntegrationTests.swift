import AVFoundation
import CryptoKit
import Photos
import UIKit
import XCTest
@testable import WezCryptSecureStudio

/// End-to-end tests against a real backend (started by CI on the same machine).
/// Configure with TEST_RUNNER_WZC_TEST_SERVER / _USER / _PASSWORD / _API_KEY.
/// When the server is not configured the tests are SKIPPED (reported as not executed).
enum TestServer {
    static var url: URL? { ProcessInfo.processInfo.environment["WZC_TEST_SERVER"].flatMap(URL.init(string:)) }
    static var username: String { ProcessInfo.processInfo.environment["WZC_TEST_USER"] ?? "ci" }
    static var password: String { ProcessInfo.processInfo.environment["WZC_TEST_PASSWORD"] ?? "" }
    static var apiKey: String { ProcessInfo.processInfo.environment["WZC_TEST_API_KEY"] ?? "" }
}

final class FlakyTransport: ChunkTransport, @unchecked Sendable {
    private let inner = ForegroundChunkTransport()
    let failAfter: Int
    let attempts = LockedBox(0)
    let succeeded = LockedBox(0)

    init(failAfter: Int) { self.failAfter = failAfter }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
        let attempt = attempts.withValue { value -> Int in value += 1; return value }
        if attempt > failAfter { throw APIError.transport(URLError(.networkConnectionLost)) }
        let result = try await inner.upload(request, fromFile: fileURL)
        if (200..<300).contains(result.0.statusCode) { succeeded.withValue { $0 += 1 } }
        return result
    }
}

class IntegrationTestCase: XCTestCase {
    var root: URL!
    var serviceName: String!

    override func setUpWithError() throws {
        guard TestServer.url != nil else { throw XCTSkip("Backend not configured (WZC_TEST_SERVER) — integration test NOT EXECUTED") }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        serviceName = "tests.integration.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    func makeAPI(method: AuthMethod = .password, secret: String? = nil, collection: String = "ci-iphone") throws -> BackupAPI {
        let credentials = CredentialStore(keychain: KeychainStore(service: serviceName))
        let config = ServerConfiguration(serverURL: try XCTUnwrap(TestServer.url), authMethod: method, username: TestServer.username, collection: collection)
        try credentials.setSecret(secret ?? (method == .password ? TestServer.password : TestServer.apiKey), for: method)
        return BackupAPI(configuration: config, credentials: credentials)
    }

    /// A vault shared by all integration tests (one account = one recovery key).
    static let sharedRecoveryKey: SymmetricKey = {
        if let text = ProcessInfo.processInfo.environment["WZC_TEST_RECOVERY_KEY"], let key = try? RecoveryKit.parse(text) { return key }
        return SymmetricKey(data: Data(repeating: 0x42, count: 32))
    }()

    func makeVault() throws -> KeyVault {
        let vault = KeyVault(keychain: KeychainStore(service: serviceName + ".vault"))
        try vault.store(recoveryKey: Self.sharedRecoveryKey)
        return vault
    }

    struct Rig {
        let engine: SyncEngine
        let store: QueueStore
        let dirs: SyncDirectories
        let conditions: LockedBox<DeviceConditions>
        let settings: LockedBox<SyncSettings>
    }

    func makeRig(api: BackupAPI, vault: KeyVault, transport: ChunkTransport, storePath: String? = nil,
                 storage: StorageGuard = StorageGuard(reserve: 0, availableCapacity: { nil }), chunkMB: Int = 8, concurrency: Int = 4) async throws -> Rig {
        let dirs = SyncDirectories(
            exports: try root.appendingPathComponent("exports").createdDirectory(),
            chunks: try root.appendingPathComponent("chunks").createdDirectory(),
            staging: try root.appendingPathComponent("staging").createdDirectory()
        )
        let store = try QueueStore(path: storePath ?? root.appendingPathComponent("queue.sqlite3").path)
        var initial = SyncSettings()
        initial.chunkSizeMB = chunkMB
        initial.maxConcurrency = concurrency
        let settings = LockedBox(initial)
        let conditions = LockedBox(DeviceConditions(network: NetworkStatus(isConnected: true, isWiFi: true), isCharging: true))
        let engine = SyncEngine(store: store, keyVault: vault, transport: transport, network: NetworkMonitor(),
                                environment: SyncEnvironment(settings: { settings.value }, conditions: { conditions.value }, photosAuthorized: { false }),
                                directories: dirs, storage: storage)
        await engine.configure(api: api)
        try await api.registerVault(fingerprint: try vault.keys().fingerprint)
        return Rig(engine: engine, store: store, dirs: dirs, conditions: conditions, settings: settings)
    }

    func stageFile(_ rig: Rig, size: Int, name: String, data: Data? = nil) async throws -> (URL, String) {
        let staged = UUID().uuidString
        let url = rig.dirs.staging.appendingPathComponent(staged)
        if let data { try data.write(to: url) } else { try ChunkPreparerTests.writeRandomFile(url, size: size) }
        let copy = root.appendingPathComponent("original-\(staged)")
        try FileManager.default.copyItem(at: url, to: copy)
        try await rig.engine.enqueueFiles([.init(localID: "file:\(staged)", displayName: name, stagedName: staged, size: Int64(size), createdAt: Date())])
        return (copy, "file:\(staged)")
    }

    func runToCompletion(_ engine: SyncEngine) async {
        await engine.start(fullScan: false)
        await engine.waitForRun()
    }

    func restoredData(api: BackupAPI, vault: KeyVault, name: String) async throws -> URL? {
        let service = RestoreService(api: api, keys: try vault.keys(), workDirectory: try root.appendingPathComponent("restore").createdDirectory())
        var cursor: String?
        repeat {
            let page = try await service.page(cursor: cursor)
            if let item = page.items.first(where: { $0.name == name }), let primary = item.manifest.primary {
                return try await service.decrypt(primary)
            }
            cursor = page.next
        } while cursor != nil
        return nil
    }

}

/// Wraps the real transport: measures how many chunk uploads run at the same time
/// and can answer the first N requests with 429/503 like a busy server would.
final class GovernedTransport: ChunkTransport, @unchecked Sendable {
    private let inner = ForegroundChunkTransport()
    let rejectFirst: Int
    let rejectStatus: Int
    let retryAfter: String?
    let current = LockedBox(0)
    let peak = LockedBox(0)
    let sent = LockedBox(0)
    let rejected = LockedBox(0)

    init(rejectFirst: Int = 0, rejectStatus: Int = 429, retryAfter: String? = nil) {
        self.rejectFirst = rejectFirst
        self.rejectStatus = rejectStatus
        self.retryAfter = retryAfter
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (HTTPURLResponse, Data) {
        let reject = rejected.withValue { value -> Bool in
            guard value < rejectFirst else { return false }
            value += 1
            return true
        }
        if reject {
            var headers = ["Content-Type": "application/json"]
            if let retryAfter { headers["Retry-After"] = retryAfter }
            let body = Data(#"{"error":{"code":"too_many_chunk_requests","message":"Server busy (test)"}}"#.utf8)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: rejectStatus, httpVersion: "HTTP/1.1", headerFields: headers))
            return (response, body)
        }
        let now = current.withValue { value -> Int in value += 1; return value }
        peak.withValue { $0 = max($0, now) }
        defer { current.withValue { $0 -= 1 } }
        let result = try await inner.upload(request, fromFile: fileURL)
        sent.withValue { $0 += 1 }
        return result
    }
}

final class UploadGovernanceIntegrationTests: IntegrationTestCase {
    /// 1,000 files through the full engine against the real backend: everything is
    /// backed up exactly once, the device never exceeds its global limit of parallel
    /// uploads, and no upload session is left open on the server.
    func testThousandFilesRespectGlobalLimitAndLeaveNoSessions() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let transport = GovernedTransport()
        let rig = try await makeRig(api: api, vault: vault, transport: transport, chunkMB: 8, concurrency: 4)
        var originals: [(URL, String)] = []
        for index in 0..<1000 {
            let data = WZCE.randomBytes(1024 + index)
            originals.append(try await stageFile(rig, size: data.count, name: "bulk-\(index)-\(UUID().uuidString).bin", data: data))
        }
        let start = Date()
        await runToCompletion(rig.engine)
        let seconds = Date().timeIntervalSince(start)
        let counts = try await rig.store.counts()
        XCTAssertEqual(counts.completed, 1000)
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(counts.remaining, 0)
        XCTAssertLessThanOrEqual(transport.peak.value, 4, "never more parallel uploads than the global limit")
        XCTAssertEqual(transport.sent.value, 1000, "every file sent exactly once (one chunk each)")
        if let stats = try? await api.uploadStats() {
            XCTAssertEqual(stats.user.openUploadSessions, 0, "no session left open on the server")
        }
        print("[benchmark] 1,000 files backed up in \(String(format: "%.1f", seconds)) s, peak parallel uploads \(transport.peak.value)")
        // Spot-check byte-exact restores.
        for index in [0, 499, 999] {
            let (original, localID) = originals[index]
            let name = try await rig.store.asset(localID)?.displayName ?? ""
            let restoredURL = try await restoredData(api: api, vault: vault, name: name)
            let restored = try XCTUnwrap(restoredURL)
            XCTAssertEqual(try FileHasher.sha256Hex(of: original), try FileHasher.sha256Hex(of: restored), "restored bytes must match the original (SHA-256)")
        }
        // Running again uploads nothing (completed files are never re-sent).
        await runToCompletion(rig.engine)
        XCTAssertEqual(transport.sent.value, 1000)
    }

    func testHTTP429WithRetryAfterIsHonouredWithoutFailures() async throws {
        try await assertPressureHandled(status: 429, retryAfter: "2", minimumWait: 2)
    }

    func testHTTP503WithoutRetryAfterBacksOffWithoutFailures() async throws {
        try await assertPressureHandled(status: 503, retryAfter: nil, minimumWait: 1)
    }

    private func assertPressureHandled(status: Int, retryAfter: String?, minimumWait: TimeInterval) async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let transport = GovernedTransport(rejectFirst: 3, rejectStatus: status, retryAfter: retryAfter)
        let rig = try await makeRig(api: api, vault: vault, transport: transport, chunkMB: 8, concurrency: 4)
        var ids: [String] = []
        for index in 0..<5 {
            ids.append(try await stageFile(rig, size: 4096, name: "pressure-\(status)-\(index)-\(UUID().uuidString).bin").1)
        }
        let start = Date()
        await runToCompletion(rig.engine)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(transport.rejected.value, 3)
        XCTAssertGreaterThanOrEqual(elapsed, minimumWait, "the engine waited for the server instead of retrying immediately")
        XCTAssertGreaterThanOrEqual(api.pressure.state.events, 3)
        for id in ids {
            let asset = try await rig.store.asset(id)
            XCTAssertEqual(asset?.state, .completed, asset?.lastError ?? "")
            XCTAssertEqual(asset?.attempts, 0, "server pressure must not use up retry attempts")
        }
        XCTAssertEqual(transport.sent.value, 5)
    }
}

final class MediaIntegrationTests: IntegrationTestCase {
    /// A ten-minute H.264 video is backed up, then downloaded through the encrypted
    /// media cache, decrypted on the device, verified byte-for-byte (SHA-256) and
    /// played and seeked by the app's player model.
    func testLongVideoDecryptsAndPlaysFromLocalFile() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        let video = root.appendingPathComponent("long.mov")
        try await PhotoKitIntegrationTests.writeVideo(to: video, frames: 1200, fps: 2, width: 320, height: 240)
        let data = try Data(contentsOf: video)
        let name = "long-video-\(UUID().uuidString).mov"
        let (original, localID) = try await stageFile(rig, size: data.count, name: name, data: data)
        await runToCompletion(rig.engine)
        let state = try await rig.store.asset(localID)?.state
        XCTAssertEqual(state, .completed)

        let service = RestoreService(api: api, keys: try vault.keys(), workDirectory: try root.appendingPathComponent("restore").createdDirectory())
        var found: VaultItem?
        var cursor: String?
        repeat {
            let page = try await service.page(cursor: cursor)
            found = page.items.first { $0.name == name }
            cursor = page.next
        } while found == nil && cursor != nil
        let item = try XCTUnwrap(found)
        let primary = try XCTUnwrap(item.manifest.primary)
        let progress = LockedBox(0.0)
        let decrypted = try await service.viewerFile(primary) { progress.value = $0 }
        defer { try? FileManager.default.removeItem(at: decrypted.deletingLastPathComponent()) }
        XCTAssertEqual(try FileHasher.sha256Hex(of: decrypted), try FileHasher.sha256Hex(of: original), "decrypted video must match the original")
        let cached = await MediaCache.shared.cachedURL(primary.objectId)
        let cachedURL = try XCTUnwrap(cached)
        let cachedHead = try FileHandle(forReadingFrom: cachedURL).read(upToCount: 4)
        XCTAssertEqual(cachedHead, Data("WZCE".utf8), "the cache holds ciphertext only")

        let check = await Self.exercisePlayer(url: decrypted, itemID: item.id)
        XCTAssertNil(check.failure)
        XCTAssertEqual(check.duration, 600, accuracy: 1)
        XCTAssertEqual(check.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(check.positionAfterSeek, 300, accuracy: 2)
        XCTAssertEqual(check.rate, 2)
        XCTAssertEqual(check.savedPosition ?? 0, 300, accuracy: 3, "the position is remembered for next time")
    }

    struct PlayerCheck: Sendable {
        let failure: String?
        let duration: Double
        let size: CGSize
        let positionAfterSeek: Double
        let rate: Float
        let savedPosition: Double?
    }

    /// Drives the app's player model on the main actor and reports what it observed.
    @MainActor
    static func exercisePlayer(url: URL, itemID: String) async -> PlayerCheck {
        let playback = VideoPlaybackModel()
        await playback.load(url: url, itemID: itemID)
        playback.seek(to: 300)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let position = CMTimeGetSeconds(playback.player.currentTime())
        playback.setRate(2)
        let rate = playback.rate
        playback.teardown()
        return PlayerCheck(failure: playback.failure, duration: playback.duration, size: playback.presentationSize,
                           positionAfterSeek: position, rate: rate, savedPosition: PlaybackPositions.position(for: itemID))
    }
}

final class IntegrationTests: IntegrationTestCase {
    // MARK: authentication

    func testIncorrectPasswordIsRejected() async throws {
        let api = try makeAPI(secret: "definitely-not-the-password")
        do {
            _ = try await api.account()
            XCTFail("login with a wrong password must fail")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_credentials")
        }
        let report = await ConnectionTester(api: api).run { _, _ in }
        XCTAssertFalse(report.succeeded)
    }

    func testUnauthorizedAccessIsRejected() async throws {
        let api = try makeAPI(method: .apiKey, secret: "wzk_forged-key-that-does-not-exist")
        do {
            _ = try await api.account()
            XCTFail("forged API key must be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 401)
        }
    }

    func testAPIKeyAuthenticationWorks() async throws {
        guard !TestServer.apiKey.isEmpty else { throw XCTSkip("No API key provided — NOT EXECUTED") }
        let account = try await makeAPI(method: .apiKey).account()
        XCTAssertEqual(account.credential, "api_key")
    }

    func testConnectionTesterFullRoundTrip() async throws {
        let states = LockedBox<[ConnectionTester.Step: ConnectionTester.StepState]>([:])
        let report = await ConnectionTester(api: try makeAPI()).run { step, state in states.withValue { $0[step] = state } }
        XCTAssertTrue(report.succeeded, "\(states.value)")
        for step in ConnectionTester.Step.allCases {
            guard case .passed = states.value[step] else { return XCTFail("\(step) did not pass: \(String(describing: states.value[step]))") }
        }
        XCTAssertGreaterThan(report.account?.diskFreeBytes ?? 0, 0)
    }

    // MARK: backup + restore

    func testLargeFileBackupAndByteExactRestore() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        let (original, localID) = try await stageFile(rig, size: 45 * 1024 * 1024 + 123, name: "large-\(UUID().uuidString).mov")
        let start = Date()
        await runToCompletion(rig.engine)
        let seconds = Date().timeIntervalSince(start)
        print("[benchmark] backed up 45 MB (encrypt + 8 MB chunks x4 parallel, loopback) in \(String(format: "%.2f", seconds)) s")
        let asset = try await rig.store.asset(localID)
        XCTAssertEqual(asset?.state, .completed, asset?.lastError ?? "")
        let staged = try FileManager.default.contentsOfDirectory(atPath: rig.dirs.staging.path)
        XCTAssertTrue(staged.isEmpty, "staged plaintext copies are deleted after verified backup")
        let chunks = try FileManager.default.contentsOfDirectory(atPath: rig.dirs.chunks.path)
        XCTAssertTrue(chunks.isEmpty, "encrypted chunk files are deleted after the server verified the object")

        let restored = try await restoredData(api: api, vault: vault, name: asset?.displayName ?? "")
        let restoredURL = try XCTUnwrap(restored)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: original.path, andPath: restoredURL.path), "restored file must be identical to the original")
    }

    func testDuplicatePrevention() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        let content = WZCE.randomBytes(300_000)
        let (_, first) = try await stageFile(rig, size: content.count, name: "dup-a.bin", data: content)
        await runToCompletion(rig.engine)
        let before = try await api.account().itemCount
        let (_, second) = try await stageFile(rig, size: content.count, name: "dup-b.bin", data: content)
        await runToCompletion(rig.engine)
        let firstState = try await rig.store.asset(first)?.state
        let secondState = try await rig.store.asset(second)?.state
        XCTAssertEqual(firstState, .completed)
        XCTAssertEqual(secondState, .duplicate)
        let after = try await api.account().itemCount
        XCTAssertEqual(before, after, "identical content must not be stored twice")
    }

    func testInterruptedUploadResumesAfterRelaunch() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let storePath = root.appendingPathComponent("relaunch.sqlite3").path
        let size = 40 * 1024 * 1024
        let chunkSize = 8 * 1024 * 1024
        let flaky = FlakyTransport(failAfter: 2)
        let rig1 = try await makeRig(api: api, vault: vault, transport: flaky, storePath: storePath, chunkMB: 8, concurrency: 1)
        let (original, localID) = try await stageFile(rig1, size: size, name: "resume-\(UUID().uuidString).mov")
        await rig1.engine.start(fullScan: false)
        for _ in 0..<600 where flaky.attempts.value <= 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)
        await rig1.engine.stopRun()
        await rig1.engine.waitForRun()
        XCTAssertEqual(flaky.succeeded.value, 2, "two chunks reached the server before the 'network loss'")

        // Relaunch: new engine and a new store instance on the same database file.
        let counting = FlakyTransport(failAfter: .max)
        let rig2 = try await makeRig(api: api, vault: vault, transport: counting, storePath: storePath, chunkMB: 8, concurrency: 4)
        await runToCompletion(rig2.engine)
        let state = try await rig2.store.asset(localID)
        XCTAssertEqual(state?.state, .completed, state?.lastError ?? "")
        let cipherSize = Int(WZCE.ciphertextSize(plaintextSize: UInt64(size), segmentSize: WZCE.defaultSegmentSize))
        let totalChunks = (cipherSize + chunkSize - 1) / chunkSize
        XCTAssertEqual(counting.succeeded.value, totalChunks - 2, "only the missing chunks are uploaded after relaunch")
        let restored = try await restoredData(api: api, vault: vault, name: state?.displayName ?? "")
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: original.path, andPath: try XCTUnwrap(restored).path))
    }

    func testLowStorageDefersWithoutWritingFiles() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport(),
                                    storage: StorageGuard(reserve: 1_000_000_000, availableCapacity: { 200_000_000 }))
        let (_, localID) = try await stageFile(rig, size: 2_000_000, name: "low-storage.bin")
        await rig.engine.start(fullScan: false)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        await rig.engine.stopRun()
        await rig.engine.waitForRun()
        let asset = try await rig.store.asset(localID)
        XCTAssertEqual(asset?.state, .pending)
        XCTAssertTrue(asset?.lastError?.contains(Formatters.bytes(200_000_000)) == true, asset?.lastError ?? "no error recorded")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: rig.dirs.chunks.path).isEmpty)
    }

    func testNetworkSwitchingPausesAndResumes() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        rig.conditions.value = DeviceConditions(network: NetworkStatus(isConnected: true, isWiFi: false, isCellular: true, isExpensive: true), isCharging: true)
        let (_, localID) = try await stageFile(rig, size: 500_000, name: "switch-\(UUID().uuidString).bin")
        await rig.engine.start(fullScan: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let waiting = try await rig.store.asset(localID)
        XCTAssertEqual(waiting?.state, .pending, "Wi‑Fi only: nothing uploads on cellular")
        rig.conditions.value = DeviceConditions(network: NetworkStatus(isConnected: true, isWiFi: true), isCharging: true)
        await rig.engine.waitForRun()
        let done = try await rig.store.asset(localID)
        XCTAssertEqual(done?.state, .completed, done?.lastError ?? "")
    }

    func testRecoveryKeyRestoreOnNewDeviceAndWrongKey() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        let name = "recovery-\(UUID().uuidString).bin"
        let (original, _) = try await stageFile(rig, size: 1_234_567, name: name)
        await runToCompletion(rig.engine)

        let newDevice = KeyVault(keychain: KeychainStore(service: serviceName + ".newdevice"))
        try newDevice.store(recoveryKey: try RecoveryKit.parse(RecoveryKit.format(Self.sharedRecoveryKey)))
        let restored = try await restoredData(api: api, vault: newDevice, name: name)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: original.path, andPath: try XCTUnwrap(restored).path))

        let wrong = RestoreService(api: api, keys: VaultKeys(recoveryKey: SymmetricKey(size: .bits256)), workDirectory: root)
        let page = try await wrong.page(cursor: nil)
        XCTAssertTrue(page.items.isEmpty, "a wrong recovery key decrypts nothing")
        XCTAssertGreaterThan(page.failures, 0)
        newDevice.erase()
    }

    func testCorruptedChunkRejectedAndTamperedDownloadDetected() async throws {
        let api = try makeAPI()
        let key = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        let prepared = try ChunkPreparer.encrypt(data: WZCE.randomBytes(400_000), objectID: id, kek: key, chunkSize: 256 * 1024, into: root)
        let session = try await api.createUpload(objectID: prepared.objectID, sizeBytes: prepared.cipherSize, chunkSize: 256 * 1024,
                                                 chunkCount: prepared.chunks.count, sha256: prepared.cipherSHA256)
        let uploadID = try XCTUnwrap(session.uploadId)
        let transport = ForegroundChunkTransport()
        let token = try await api.bearerToken()
        let bad = try api.chunkRequest(uploadID: uploadID, index: 0, sha256: String(repeating: "0", count: 64), token: token)
        let (badResponse, badBody) = try await transport.upload(bad, fromFile: prepared.chunks[0].url)
        XCTAssertEqual(badResponse.statusCode, 400)
        XCTAssertEqual(APIError.from(status: 400, data: badBody).code, "checksum_mismatch")
        for chunk in prepared.chunks {
            let (response, _) = try await transport.upload(try api.chunkRequest(uploadID: uploadID, index: chunk.index, sha256: chunk.sha256, token: token), fromFile: chunk.url)
            XCTAssertEqual(response.statusCode, 200)
        }
        _ = try await api.completeUpload(uploadID)
        let downloaded = try await api.downloadObject(prepared.objectID, to: root)
        var blob = try Data(contentsOf: downloaded)
        blob[blob.count - 40] ^= 0x01
        try blob.write(to: downloaded)
        XCTAssertThrowsError(try WZCE.decryptFile(at: downloaded, to: root.appendingPathComponent("out"), kek: key, expectedObjectID: id)) { error in
            guard case WZCE.Failure.segmentAuthenticationFailed = error else { return XCTFail("expected authentication failure, got \(error)") }
        }
        try await api.deleteObject(prepared.objectID)
    }

    func testBackgroundURLSessionTransfer() async throws {
        let api = try makeAPI()
        let key = SymmetricKey(size: .bits256)
        let prepared = try ChunkPreparer.encrypt(data: WZCE.randomBytes(600_000), objectID: WZCE.randomBytes(16), kek: key, chunkSize: 256 * 1024, into: root)
        let session = try await api.createUpload(objectID: prepared.objectID, sizeBytes: prepared.cipherSize, chunkSize: 256 * 1024,
                                                 chunkCount: prepared.chunks.count, sha256: prepared.cipherSHA256)
        let uploadID = try XCTUnwrap(session.uploadId)
        let transport = BackgroundChunkTransport(identifier: "com.wezcrypt.securestudio.tests.\(UUID().uuidString)")
        let token = try await api.bearerToken()
        for chunk in prepared.chunks {
            let (response, body) = try await transport.upload(try api.chunkRequest(uploadID: uploadID, index: chunk.index, sha256: chunk.sha256, token: token), fromFile: chunk.url)
            XCTAssertEqual(response.statusCode, 200, String(data: body, encoding: .utf8) ?? "")
        }
        let completed = try await api.completeUpload(uploadID)
        XCTAssertEqual(completed.sha256, prepared.cipherSHA256)
        try await api.deleteObject(prepared.objectID)
    }

    func testUploadConcurrencyAndChunkSizeBenchmark() async throws {
        let api = try makeAPI()
        let vault = try makeVault()
        for (chunkMB, concurrency) in [(8, 1), (8, 4), (16, 4), (16, 8)] {
            let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport(),
                                        storePath: root.appendingPathComponent("bench-\(chunkMB)-\(concurrency).sqlite3").path, chunkMB: chunkMB, concurrency: concurrency)
            _ = try await stageFile(rig, size: 64 * 1024 * 1024, name: "bench-\(UUID().uuidString).bin")
            let start = Date()
            await runToCompletion(rig.engine)
            let seconds = Date().timeIntervalSince(start)
            print("[benchmark] 64 MB backup chunk=\(chunkMB)MB parallel=\(concurrency): \(String(format: "%.2f", seconds)) s (\(Formatters.speed(64 * 1024 * 1024 / seconds))) — loopback, not representative of real networks")
        }
    }
}

/// TLS validation against public test hosts (requires internet on the test machine).
final class TLSTests: XCTestCase {
    func assertRejected(_ host: String) async throws {
        let credentials = CredentialStore(keychain: KeychainStore(service: "tests.tls.\(UUID().uuidString)"))
        try credentials.setSecret("x", for: .apiKey)
        let api = BackupAPI(configuration: ServerConfiguration(serverURL: URL(string: "https://\(host)")!, authMethod: .apiKey, username: "x", collection: "x"),
                            credentials: credentials)
        do {
            try await api.health()
            XCTFail("\(host): connection to an untrusted certificate must fail")
        } catch let error as APIError {
            if case .transport(let urlError) = error, [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(urlError.code) {
                throw XCTSkip("No internet access to \(host) — TLS test NOT EXECUTED")
            }
            XCTAssertTrue(error.isTLSFailure, "\(host): expected TLS failure, got \(error)")
        }
    }

    func testExpiredCertificateRejected() async throws { try await assertRejected("expired.badssl.com") }
    func testSelfSignedCertificateRejected() async throws { try await assertRejected("self-signed.badssl.com") }
    func testUntrustedRootRejected() async throws { try await assertRejected("untrusted-root.badssl.com") }
    func testWrongHostRejected() async throws { try await assertRejected("wrong.host.badssl.com") }
}

/// PhotoKit pipeline on the simulator: needs Photos access granted beforehand
/// (CI runs `xcrun simctl privacy <device> grant photos-add/photos com.wezcrypt.securestudio`).
final class PhotoKitIntegrationTests: IntegrationTestCase {
    func testPhotoAndVideoOriginalsBackUpAndRestore() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Photos access not granted on this simulator (status \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)) — PhotoKit test NOT EXECUTED")
        }
        let imageURL = root.appendingPathComponent("test.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)
        let videoURL = root.appendingPathComponent("test.mov")
        try await Self.writeVideo(to: videoURL)

        let ids = LockedBox<[String]>([])
        try await PHPhotoLibrary.shared().performChanges {
            let photo = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: imageURL)
            let video = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            ids.value = [photo?.placeholderForCreatedAsset?.localIdentifier, video?.placeholderForCreatedAsset?.localIdentifier].compactMap { $0 }
        }
        XCTAssertEqual(ids.value.count, 2)

        let api = try makeAPI()
        let vault = try makeVault()
        let rig = try await makeRig(api: api, vault: vault, transport: ForegroundChunkTransport())
        let photosEngine = SyncEngine(store: rig.store, keyVault: vault, transport: ForegroundChunkTransport(), network: NetworkMonitor(),
                                      environment: SyncEnvironment(settings: { rig.settings.value }, conditions: { rig.conditions.value }), directories: rig.dirs)
        await photosEngine.configure(api: api)
        await photosEngine.start(fullScan: true)
        await photosEngine.waitForRun()

        let service = RestoreService(api: api, keys: try vault.keys(), workDirectory: root)
        for localID in ids.value {
            let asset = try await rig.store.asset(localID)
            XCTAssertTrue(asset?.state == .completed || asset?.state == .duplicate, "\(localID): \(asset?.lastError ?? "not backed up")")
            let exported = try await ResourceExporter(directory: root).export(localID: localID, storage: StorageGuard(reserve: 0, availableCapacity: { nil }))
            let original = try XCTUnwrap(exported.primary)
            let originalSHA = try FileHasher.sha256Hex(of: original.fileURL)
            var found: VaultItem?
            var cursor: String?
            repeat {
                let page = try await service.page(cursor: cursor)
                found = page.items.first { $0.manifest.primary?.sha256 == originalSHA }
                cursor = page.next
            } while found == nil && cursor != nil
            let item = try XCTUnwrap(found, "backup of \(original.filename) not found on the server")
            let restored = try await service.decrypt(try XCTUnwrap(item.manifest.primary))
            XCTAssertEqual(try FileHasher.sha256Hex(of: restored), originalSHA, "restored original must be bit-identical")
            try await service.restoreToPhotos(item)
        }
    }

    static func writeVideo(to url: URL, frames: Int = 30, fps: Int32 = 30, width: Int = 64, height: Int = 64) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32((frame * 8) % 256), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? URLError(.unknown) }
    }
}
