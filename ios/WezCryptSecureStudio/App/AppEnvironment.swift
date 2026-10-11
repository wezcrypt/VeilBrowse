import Foundation
import Observation
import SwiftUI

/// Composition root. Created once (also reachable from the app delegate for
/// background launches) and injected into SwiftUI with `.environment`.
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let keychain: KeychainStore
    let deviceKeys: DeviceKeyManager
    let credentials: SessionCredentialStore
    let api: APIClient
    let auth: AuthManager
    let lock: AppLockController
    let photos: PhotoLibraryService
    let network: NetworkMonitor
    let transport: ChunkTransport
    let cacheCrypto: LocalCacheCrypto
    let images: RemoteImageLoader
    let albums: AlbumStore
    let syncStore: SyncStore
    let syncEngine: SyncEngine
    let sync: SyncController
    private(set) var startupWarning: String?
    private var didBootstrap = false

    private init() {
        let settings = AppSettings()
        let keychain = KeychainStore()
        let deviceKeys = DeviceKeyManager(keychain: keychain)
        let credentials = SessionCredentialStore(keychain: keychain)
        let api = APIClient(baseURL: AppConfig.apiBaseURL, credentials: credentials, deviceKeys: deviceKeys)
        let network = NetworkMonitor()
        let transport = ChunkTransport()
        let cacheCrypto = LocalCacheCrypto(keychain: keychain)

        var warning: String?
        let store: SyncStore
        do {
            let url = try AppDirectories.applicationSupport().appendingPathComponent("sync.sqlite3")
            store = try SyncStore(path: url.path)
        } catch {
            warning = String(localized: "Sync state could not be saved on this device: \(error.localizedDescription)")
            Log.app.error("Falling back to in-memory sync store: \(error.localizedDescription, privacy: .public)")
            // ":memory:" cannot fail to open unless SQLite itself is unavailable.
            store = try! SyncStore(path: ":memory:")
        }

        let engine: SyncEngine
        do {
            engine = try SyncEngine(store: store, api: api, transport: transport, network: network, policy: settings.syncPolicy)
        } catch {
            fatalError("Temporary directories are unavailable: \(error)")
        }

        self.settings = settings
        self.keychain = keychain
        self.deviceKeys = deviceKeys
        self.credentials = credentials
        self.api = api
        self.network = network
        self.transport = transport
        self.cacheCrypto = cacheCrypto
        self.syncStore = store
        self.syncEngine = engine
        auth = AuthManager(api: api, credentials: credentials, deviceKeys: deviceKeys)
        lock = AppLockController(settings: settings)
        photos = PhotoLibraryService()
        images = RemoteImageLoader(api: api, crypto: cacheCrypto)
        albums = AlbumStore(api: api)
        sync = SyncController(engine: engine, store: store, settings: settings, network: network)
        startupWarning = warning

        auth.onSignedOut = { [weak self] in
            await self?.wipeLocalData()
        }
        transport.activate()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        AppDirectories.wipe(FileManager.default.temporaryDirectory.appendingPathComponent("Viewer"))
        await auth.bootstrap()
        lock.lockOnLaunch(signedIn: auth.isSignedIn)
        if auth.isSignedIn {
            await signedInStartup()
        }
    }

    func signedInStartup() async {
        await sync.refreshCounts()
        if settings.autoSyncOnLaunch, photos.hasAccess {
            sync.syncIncremental()
        }
        if settings.backgroundSyncEnabled {
            BackgroundSyncScheduler.schedule(requiresExternalPower: settings.backgroundRequiresPower)
        }
    }

    /// Removes every trace of the previous session from this device.
    private func wipeLocalData() async {
        BackgroundSyncScheduler.cancelAll()
        await sync.resetForSignOut()
        await images.clear()
        cacheCrypto.destroyKey()
        albums.reset()
        AppDirectories.wipe(FileManager.default.temporaryDirectory.appendingPathComponent("Viewer"))
        lock.lockOnLaunch(signedIn: false)
        Log.app.info("Local data wiped after sign-out")
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            lock.sceneBecameActive(signedIn: auth.isSignedIn)
            photos.refreshAuthorization()
            sync.appWillEnterForeground()
        case .inactive:
            lock.sceneBecameInactive()
        case .background:
            lock.sceneEnteredBackground()
            sync.appDidEnterBackground()
            if auth.isSignedIn, settings.backgroundSyncEnabled {
                BackgroundSyncScheduler.schedule(requiresExternalPower: settings.backgroundRequiresPower)
            }
        @unknown default:
            break
        }
    }
}
