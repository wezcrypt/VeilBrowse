import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Main-actor façade over `SyncEngine` for the UI.
@MainActor
@Observable
final class SyncController {
    private(set) var snapshot = SyncSnapshot()
    private(set) var deviceFreeSpace: Int64?
    private(set) var completedLocalIDs: Set<String> = []
    private(set) var networkStatus = NetworkStatus()
    private let engine: SyncEngine
    private let store: SyncStore
    private let settings: AppSettings
    private var observeTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(engine: SyncEngine, store: SyncStore, settings: AppSettings, network: NetworkMonitor) {
        self.engine = engine
        self.store = store
        self.settings = settings
        networkTask = Task { [weak self, network] in
            for await status in network.updates() {
                self?.networkStatus = status
            }
        }
        observeTask = Task { [weak self, engine] in
            for await snapshot in await engine.snapshots() {
                guard let self else { return }
                let finishedNow = self.snapshot.isRunning && !snapshot.isRunning
                self.snapshot = snapshot
                if finishedNow { await self.reloadCompletedIDs() }
            }
        }
        refreshDeviceSpace()
    }

    var isRunning: Bool { snapshot.isRunning }

    var statusText: String {
        switch snapshot.phase {
        case .idle:
            return snapshot.counts.remaining > 0 ? String(localized: "\(snapshot.counts.remaining) items waiting") : String(localized: "Up to date")
        case .scanning(let discovered):
            return discovered > 0 ? String(localized: "Scanning library… \(discovered) items") : String(localized: "Scanning library…")
        case .uploading:
            return String(localized: "Uploading \(snapshot.counts.remaining) items")
        case .waiting(let reason):
            return reason
        case .paused:
            return String(localized: "Paused")
        case .needsPermission:
            return String(localized: "Photo library access is required")
        case .signedOut:
            return String(localized: "Link this iPhone to start syncing")
        case .finished:
            return snapshot.counts.failed > 0 ? String(localized: "Finished with \(snapshot.counts.failed) failed") : String(localized: "All items synced")
        case .failed(let message):
            return message
        }
    }

    var overallProgress: Double {
        let counts = snapshot.counts
        guard counts.total > 0 else { return 0 }
        let activeFraction = snapshot.active.reduce(0.0) { $0 + $1.fraction }
        return min(1, (Double(counts.completed) + activeFraction) / Double(counts.total))
    }

    // MARK: Actions

    func syncAll() {
        Task { await engine.updatePolicy(settings.syncPolicy); await engine.start(fullScan: true) }
    }

    func syncIncremental() {
        Task { await engine.updatePolicy(settings.syncPolicy); await engine.start(fullScan: false) }
    }

    func pause() {
        Task { await engine.pause() }
    }

    func resume() {
        Task { await engine.updatePolicy(settings.syncPolicy); await engine.resume() }
    }

    func retryFailed() {
        Task { await engine.retryFailed() }
    }

    func retry(_ record: SyncRecord) {
        Task { await engine.retry(record.localID) }
    }

    func policyChanged() {
        Task { await engine.updatePolicy(settings.syncPolicy) }
    }

    func records(for state: SyncState, limit: Int = 200, offset: Int = 0) async -> [SyncRecord] {
        (try? await store.records(state: state, limit: limit, offset: offset)) ?? []
    }

    func reloadCompletedIDs() async {
        completedLocalIDs = (try? await store.completedLocalIDs()) ?? []
    }

    func refreshDeviceSpace() {
        deviceFreeSpace = AppDirectories.availableDeviceCapacity()
    }

    func refreshCounts() async {
        await engine.refreshCounts(force: true)
    }

    func resetForSignOut() async {
        await engine.reset()
        completedLocalIDs = []
    }

    // MARK: Lifecycle

    /// Gives the current chunk time to finish when the app is backgrounded.
    func appDidEnterBackground() {
        guard snapshot.isRunning, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WezCryptSync") { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.engine.cancelRun()
                self.endBackgroundTask()
            }
        }
        Task { [weak self, engine] in
            await engine.waitForCurrentRun()
            await MainActor.run { self?.endBackgroundTask() }
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
        refreshDeviceSpace()
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    /// Runs one sync pass for a BGProcessingTask / BGAppRefreshTask.
    func runBackgroundPass(_ task: BGTask) {
        let engine = engine
        let policy = settings.syncPolicy
        let work = Task {
            await engine.updatePolicy(policy)
            await engine.start(fullScan: false)
            await engine.waitForCurrentRun()
            return !Task.isCancelled
        }
        let box = UncheckedSendable(task)
        task.expirationHandler = { @Sendable in
            work.cancel()
            Task { await engine.cancelRun() }
        }
        Task {
            let success = await work.value
            box.value.setTaskCompleted(success: success)
        }
    }
}

enum BackgroundSyncScheduler {
    static func register(handler: @escaping @Sendable (BGTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.syncProcessingTaskIdentifier, using: nil) { task in
            handler(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.appRefreshTaskIdentifier, using: nil) { task in
            handler(task)
        }
    }

    /// iOS decides when (and whether) these run; they are opportunistic, not continuous.
    static func schedule(requiresExternalPower: Bool) {
        let processing = BGProcessingTaskRequest(identifier: AppConfig.syncProcessingTaskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = requiresExternalPower
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: AppConfig.appRefreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(processing)
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            Log.sync.notice("Background task scheduling unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancelAll() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}
