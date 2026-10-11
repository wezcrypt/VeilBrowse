import BackgroundTasks
import Foundation
import Observation
import UIKit

/// Main-actor façade over `SyncEngine`: exposes the live snapshot, sync
/// settings and device conditions (thermal state, Low Power Mode, battery,
/// network) to the UI and the engine.
@MainActor
@Observable
final class SyncController {
    private(set) var snapshot = SyncSnapshot()
    private(set) var conditions = DeviceConditions()
    private(set) var completedPhotoIDs: Set<String> = []
    var settings: SyncSettings {
        didSet {
            settings.save()
            settingsBox.value = settings
            if settings.backgroundSync != oldValue.backgroundSync || settings.chargingOnly != oldValue.chargingOnly {
                rescheduleBackground()
            }
        }
    }

    let engine: SyncEngine
    let store: QueueStore
    private let network: NetworkMonitor
    private var tasks: [Task<Void, Never>] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let conditionsBox: LockedBox<DeviceConditions>
    private let settingsBox: LockedBox<SyncSettings>

    /// `settingsBox`/`conditionsBox` are shared with the engine, which reads them from its own executor.
    init(engine: SyncEngine, store: QueueStore, network: NetworkMonitor, settingsBox: LockedBox<SyncSettings>, conditionsBox: LockedBox<DeviceConditions>) {
        self.engine = engine
        self.store = store
        self.network = network
        self.settings = settingsBox.value
        self.settingsBox = settingsBox
        self.conditionsBox = conditionsBox
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateConditions()
        tasks.append(Task { [weak self, engine] in
            for await snapshot in await engine.snapshots() {
                guard let self else { return }
                let finished = self.snapshot.isRunning && !snapshot.isRunning
                self.snapshot = snapshot
                if finished { await self.reloadCompletedIDs() }
            }
        })
        tasks.append(Task { [weak self, network] in
            for await _ in network.updates() { self?.updateConditions() }
        })
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification] {
            tasks.append(Task { [weak self] in
                for await _ in center.notifications(named: name) { self?.updateConditions() }
            })
        }
    }

    private func updateConditions() {
        let device = UIDevice.current
        let value = DeviceConditions(
            network: network.status,
            thermal: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            batteryLevel: device.batteryLevel
        )
        conditions = value
        conditionsBox.value = value
    }

    var decision: TransferDecision { TransferPolicy.decide(settings: settings, conditions: conditions) }

    var statusText: String {
        switch snapshot.phase {
        case .idle:
            return snapshot.counts.remaining > 0 ? String(localized: "\(snapshot.counts.remaining) items waiting") : String(localized: "Ready")
        case .scanning(let count): return String(localized: "Scanning library… \(count)")
        case .running: return String(localized: "Backing up \(snapshot.counts.remaining) items")
        case .waiting(let reason): return reason
        case .paused: return String(localized: "Paused")
        case .finished: return snapshot.counts.failed > 0 ? String(localized: "Done · \(snapshot.counts.failed) failed") : String(localized: "Everything is backed up")
        case .failed(let message): return message
        case .needsSetup(let message): return message
        }
    }

    var progress: Double {
        let counts = snapshot.counts
        guard counts.total > 0 else { return 0 }
        let partial = snapshot.active.reduce(0.0) { $0 + $1.fraction }
        return min(1, (Double(counts.completed) + partial) / Double(counts.total))
    }

    // MARK: Actions

    func start(fullScan: Bool = false) { Task { await engine.start(fullScan: fullScan) } }
    func pause() { Task { await engine.pause() } }
    func cancel() { Task { await engine.cancel() } }
    func retryFailed() { Task { await engine.retryFailed() } }
    func retry(_ asset: QueueAsset) { Task { await engine.retry(asset.localID) } }

    func assets(_ states: [AssetState], limit: Int = 200, offset: Int = 0) async -> [QueueAsset] {
        (try? await store.assets(states: states, limit: limit, offset: offset)) ?? []
    }

    func reloadCompletedIDs() async {
        completedPhotoIDs = (try? await store.completedLocalIDs()) ?? []
    }

    func refresh() async { await engine.refreshCounts() }

    // MARK: Background

    func appDidEnterBackground() {
        rescheduleBackground()
        guard snapshot.isRunning, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WezCryptBackup") { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.engine.stopRun()
                self.endBackgroundTask()
            }
        }
        Task { [weak self, engine] in
            await engine.waitForRun()
            self?.endBackgroundTask()
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
        updateConditions()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func rescheduleBackground() {
        if settings.backgroundSync {
            BackgroundScheduler.schedule(requiresPower: settings.chargingOnly)
        } else {
            BackgroundScheduler.cancel()
        }
    }

    /// One opportunistic background pass (BGProcessingTask / BGAppRefreshTask).
    func handle(_ task: BGTask) {
        rescheduleBackground()
        let engine = engine
        let work = Task {
            await engine.start(fullScan: false)
            await engine.waitForRun()
            return !Task.isCancelled
        }
        let box = UncheckedSendable(task)
        task.expirationHandler = { @Sendable in
            work.cancel()
            Task { await engine.stopRun() }
        }
        Task {
            let success = await work.value
            box.value.setTaskCompleted(success: success)
        }
    }
}

/// iOS decides if and when these run (typically while charging on Wi‑Fi);
/// background execution is opportunistic and time-limited, never continuous.
enum BackgroundScheduler {
    static func register(handler: @escaping @Sendable (BGTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.processingTaskIdentifier, using: nil) { handler($0) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.refreshTaskIdentifier, using: nil) { handler($0) }
    }

    static func schedule(requiresPower: Bool) {
        let processing = BGProcessingTaskRequest(identifier: AppConfig.processingTaskIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = requiresPower
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: AppConfig.refreshTaskIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(processing)
            try BGTaskScheduler.shared.submit(refresh)
        } catch {
            Log.sync.notice("Background scheduling unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}
