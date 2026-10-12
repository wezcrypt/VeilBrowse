import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Composition root and onboarding state machine.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Stage: Equatable {
        case welcome
        case serverSetup
        case connectionTest
        case recovery
        case permissions
        case ready
    }

    private(set) var stage: Stage = .welcome
    private(set) var configuration: ServerConfiguration?
    private(set) var api: BackupAPI?
    private(set) var account: AccountInfo?
    private(set) var startupWarning: String?

    let keychain: KeychainStore
    let credentials: CredentialStore
    let keyVault: KeyVault
    let network: NetworkMonitor
    let transport: BackgroundChunkTransport
    let store: QueueStore
    let engine: SyncEngine
    let sync: SyncController
    let photos: PhotoLibrary
    let security: SecuritySettings
    let lock: AppLockController
    let directories: SyncDirectories

    private static let onboardedKey = "onboarding.completed.v2"

    private init() {
        keychain = KeychainStore()
        credentials = CredentialStore(keychain: keychain)
        keyVault = KeyVault(keychain: keychain)
        network = NetworkMonitor()
        transport = BackgroundChunkTransport()
        security = SecuritySettings()
        lock = AppLockController(settings: security)
        photos = PhotoLibrary()

        var warning: String?
        let dirs: SyncDirectories
        do {
            dirs = try SyncDirectories.standard()
        } catch {
            fatalError("App storage directories are unavailable: \(error)")
        }
        directories = dirs
        let queue: QueueStore
        do {
            queue = try QueueStore(path: try AppDirectories.applicationSupport().appendingPathComponent("queue.sqlite3").path)
        } catch {
            warning = String(localized: "The backup queue could not be opened; progress will not survive a restart. \(error.localizedDescription)")
            queue = try! QueueStore(path: ":memory:")
        }
        store = queue

        let settingsBox = LockedBox(SyncSettings.load())
        let conditionsBox = LockedBox(DeviceConditions())
        engine = SyncEngine(
            store: queue,
            keyVault: keyVault,
            transport: transport,
            network: network,
            environment: SyncEnvironment(
                settings: { settingsBox.value },
                conditions: { conditionsBox.value }
            ),
            directories: dirs
        )
        sync = SyncController(engine: engine, store: queue, network: network, settingsBox: settingsBox, conditionsBox: conditionsBox)
        startupWarning = warning

        #if DEBUG
        // UI tests start from a clean slate.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            ServerConfiguration.clear()
            credentials.eraseAll()
            keyVault.erase()
            UserDefaults.standard.removeObject(forKey: Self.onboardedKey)
        }
        #endif
        configuration = ServerConfiguration.load()
        if let configuration {
            api = BackupAPI(configuration: configuration, credentials: credentials)
        }
        transport.activate()
        stage = computeStage()
    }

    private func computeStage() -> Stage {
        guard configuration != nil else { return .welcome }
        guard keyVault.isConfigured else { return .recovery }
        guard UserDefaults.standard.bool(forKey: Self.onboardedKey) else { return .permissions }
        return .ready
    }

    func bootstrap() async {
        await engine.configure(api: api)
        lock.lockOnLaunch(signedIn: stage == .ready)
        AppDirectories.wipe(FileManager.default.temporaryDirectory.appendingPathComponent("Restore"))
        if stage == .ready {
            await sync.refresh()
            await refreshAccount()
            if photos.hasAccess { sync.start() }
            sync.rescheduleBackground()
        }
    }

    // MARK: - Onboarding

    func go(to stage: Stage) {
        withAnimation(.snappy) { self.stage = stage }
    }

    /// Persists the configuration (secrets go to the Keychain only).
    func saveConfiguration(_ configuration: ServerConfiguration, secret: String) async throws {
        try configuration.validate(secret: secret)
        if let api, api.configuration.serverURL != configuration.serverURL || api.configuration.username != configuration.username {
            await api.logout()
        }
        try credentials.setSecret(secret, for: configuration.authMethod)
        try configuration.save()
        self.configuration = configuration
        let api = BackupAPI(configuration: configuration, credentials: credentials)
        self.api = api
        await engine.configure(api: api)
    }

    func testConnection(update: @escaping @Sendable (ConnectionTester.Step, ConnectionTester.StepState) async -> Void) async -> ConnectionTester.Report {
        guard let api else { return .init(succeeded: false) }
        let report = await ConnectionTester(api: api).run(update: update)
        account = report.account
        return report
    }

    /// New vault: stores the key locally and registers its public fingerprint.
    func adoptRecoveryKey(_ key: SymmetricKeyBox) async throws {
        guard let api else { throw APIError.notConfigured }
        let fingerprint = VaultKeys(recoveryKey: key.key).fingerprint
        if let existing = try await api.vault()?.fingerprint, existing != fingerprint {
            throw RecoveryKeyError.mismatch
        }
        try await api.registerVault(fingerprint: fingerprint)
        try keyVault.store(recoveryKey: key.key)
    }

    /// After a successful connection test: reuse an existing local key if it matches the server.
    func continueAfterConnectionTest(report: ConnectionTester.Report) async {
        guard keyVault.isConfigured, let local = keyVault.fingerprint else { go(to: .recovery); return }
        if let remote = report.vaultFingerprint, remote != local {
            go(to: .recovery)
            return
        }
        if report.vaultFingerprint == nil { try? await api?.registerVault(fingerprint: local) }
        go(to: UserDefaults.standard.bool(forKey: Self.onboardedKey) ? .ready : .permissions)
        if stage == .ready {
            await engine.configure(api: api)
            sync.start()
        }
    }

    func serverHasVault() async throws -> Bool {
        guard let api else { throw APIError.notConfigured }
        return try await api.vault() != nil
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        go(to: .ready)
        Task {
            await refreshAccount()
            sync.start(fullScan: true)
            sync.rescheduleBackground()
        }
    }

    func refreshAccount() async {
        guard let api else { return }
        if let info = try? await api.account() { account = info }
    }

    // MARK: - Files

    func importFiles(_ urls: [URL]) async -> [String] {
        let importer = FileImporter(stagingDirectory: directories.staging, storage: StorageGuard())
        let result: (imported: [FileImporter.Imported], failures: [String]) = await Task.detached {
            do {
                return try importer.importFiles(urls)
            } catch {
                return (imported: [], failures: [error.localizedDescription])
            }
        }.value
        do {
            try await engine.enqueueFiles(result.imported)
        } catch {
            return result.failures + [error.localizedDescription]
        }
        if !result.imported.isEmpty { sync.start() }
        return result.failures
    }

    // MARK: - Restore

    func restoreService() throws -> RestoreService {
        guard let api else { throw APIError.notConfigured }
        let directory = try AppDirectories.secureTemp("Restore")
        return RestoreService(api: api, keys: try keyVault.keys(), workDirectory: directory)
    }

    // MARK: - Sign out

    /// Disconnects this iPhone. Encrypted backups on the server are untouched.
    /// When `forgetRecoveryKey` is true the local copy of the key is erased too.
    func disconnect(forgetRecoveryKey: Bool) async {
        await engine.cancel()
        await api?.logout()
        await engine.reset()
        await engine.configure(api: nil)
        credentials.eraseAll()
        ServerConfiguration.clear()
        UserDefaults.standard.removeObject(forKey: Self.onboardedKey)
        if forgetRecoveryKey { keyVault.erase() }
        BackgroundScheduler.cancel()
        configuration = nil
        api = nil
        account = nil
        go(to: .welcome)
    }

    // MARK: - Lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            lock.sceneBecameActive(signedIn: stage == .ready)
            photos.refresh()
            sync.appWillEnterForeground()
            if stage == .ready, photos.hasAccess, !sync.snapshot.isRunning, sync.snapshot.phase != .paused { sync.start() }
        case .inactive:
            lock.sceneBecameInactive()
        case .background:
            lock.sceneEnteredBackground()
            sync.appDidEnterBackground()
        @unknown default:
            break
        }
    }
}

enum RecoveryKeyError: Error, LocalizedError {
    case mismatch

    var errorDescription: String? {
        String(localized: "This recovery key does not match the backups already stored for this account.")
    }
}

/// Sendable wrapper for a recovery key moving between views.
struct SymmetricKeyBox: @unchecked Sendable {
    let key: SymmetricKey
}
