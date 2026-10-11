import Foundation
import Network

struct NetworkStatus: Sendable, Equatable {
    var isConnected = false
    var isWiFi = false
    var isCellular = false
    var isExpensive = false
    var isConstrained = false

    func allows(_ policy: SyncPolicy) -> Bool {
        guard isConnected else { return false }
        if policy.respectLowDataMode && isConstrained { return false }
        switch policy.networkMode {
        case .wifiOnly: return isWiFi && !isExpensive
        case .wifiAndCellular: return true
        }
    }

    func blockReason(_ policy: SyncPolicy) -> String? {
        if !isConnected { return String(localized: "Waiting for a network connection") }
        if policy.respectLowDataMode && isConstrained { return String(localized: "Paused by Low Data Mode") }
        if policy.networkMode == .wifiOnly && (!isWiFi || isExpensive) { return String(localized: "Waiting for Wi‑Fi") }
        return nil
    }
}

/// NWPathMonitor wrapper exposing the current status and an async change stream.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wezcrypt.securestudio.network")
    private let state = LockedBox(NetworkStatus())
    private let continuations = LockedBox<[UUID: AsyncStream<NetworkStatus>.Continuation]>([:])

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = NetworkStatus(
                isConnected: path.status == .satisfied,
                isWiFi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                isCellular: path.usesInterfaceType(.cellular),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            self.state.value = status
            for continuation in self.continuations.value.values {
                continuation.yield(status)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var status: NetworkStatus { state.value }

    func updates() -> AsyncStream<NetworkStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(state.value)
            continuations.withValue { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.continuations.withValue { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    /// Suspends until the policy allows uploads (or the task is cancelled).
    func waitUntilAllowed(_ policy: SyncPolicy) async throws {
        if status.allows(policy) { return }
        for await update in updates() {
            try Task.checkCancellation()
            if update.allows(policy) { return }
        }
        try Task.checkCancellation()
    }
}
