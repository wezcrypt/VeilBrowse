import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var importMessages: [String] = []
    @State private var confirmCancel = false

    var body: some View {
        let sync = model.sync
        let snapshot = sync.snapshot
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let warning = model.startupWarning { ErrorBanner(message: warning) }
                    statusCard(sync: sync, snapshot: snapshot)
                    pressureCard(snapshot)
                    statsGrid(snapshot)
                    conditionsCard(sync)
                    backgroundCard(snapshot, sync: sync)
                    if !snapshot.active.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "In Progress")).font(.headline)
                                ForEach(snapshot.active) { ActiveTransferRow(transfer: $0) }
                            }
                        }
                    }
                    serverCard
                    ForEach(importMessages, id: \.self) { ErrorBanner(message: $0) }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "Dashboard"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "doc.badge.plus") }
                        .accessibilityLabel(String(localized: "Back Up Files"))
                }
            }
            .refreshable {
                await sync.refresh()
                await model.refreshAccount()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { importMessages = await model.importFiles(urls) }
                case .failure(let error): importMessages = [error.localizedDescription]
                }
            }
            .confirmationDialog(String(localized: "Cancel the current backup?"), isPresented: $confirmCancel, titleVisibility: .visible) {
                Button(String(localized: "Cancel Backup"), role: .destructive) { sync.cancel() }
            } message: {
                Text(String(localized: "Encrypted files prepared on this iPhone are discarded. Items stay queued and nothing is deleted from Photos or the server."))
            }
        }
    }

    private func statusCard(sync: SyncController, snapshot: SyncSnapshot) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Backup")).font(.title2.bold())
                        Text(sync.statusText).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("syncStatus")
                    }
                    Spacer()
                    if snapshot.isRunning { ProgressView() }
                }
                ProgressView(value: sync.progress).tint(Theme.accent)
                    .accessibilityLabel(String(localized: "Backup progress"))
                if let error = snapshot.lastError, !snapshot.isRunning {
                    Text(error).font(.caption).foregroundStyle(Theme.warning)
                }
                HStack(spacing: 10) {
                    if snapshot.isRunning {
                        Button { sync.pause() } label: { Label(String(localized: "Pause"), systemImage: "pause.fill") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button(role: .destructive) { confirmCancel = true } label: { Label(String(localized: "Cancel"), systemImage: "xmark") }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button { sync.start(fullScan: snapshot.counts.total == 0) } label: {
                            Label(snapshot.phase == .paused ? String(localized: "Resume") : String(localized: "Start Backup"), systemImage: "arrow.up.circle.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("startBackupButton")
                    }
                }
            }
        }
    }

    private func statsGrid(_ snapshot: SyncSnapshot) -> some View {
        let counts = snapshot.counts
        return GlassCard {
            Grid(horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    StatTile(title: String(localized: "Total files"), value: "\(counts.total)", symbol: "square.stack.3d.up")
                    StatTile(title: String(localized: "Backed up"), value: "\(counts.completed)", symbol: "checkmark.icloud")
                    StatTile(title: String(localized: "Remaining"), value: "\(counts.remaining)", symbol: "tray.full")
                }
                GridRow {
                    StatTile(title: String(localized: "Failed"), value: "\(counts.failed)", symbol: "exclamationmark.triangle")
                    StatTile(title: String(localized: "Uploaded"), value: Formatters.gigabytes(snapshot.uploadedBytes), symbol: "arrow.up.doc")
                    StatTile(title: String(localized: "Left to upload"), value: Formatters.gigabytes(snapshot.remainingBytes), symbol: "externaldrive")
                }
                GridRow {
                    StatTile(title: String(localized: "Speed now"), value: Formatters.speed(snapshot.bytesPerSecond), symbol: "speedometer")
                    StatTile(title: String(localized: "Average (2 min)"), value: Formatters.speed(snapshot.averageBytesPerSecond), symbol: "gauge.with.dots.needle.50percent")
                    StatTile(title: String(localized: "Time left"), value: snapshot.isRunning ? Formatters.eta(snapshot.etaSeconds) : "—", symbol: "clock")
                }
                GridRow {
                    StatTile(title: String(localized: "Connections"),
                             value: snapshot.isRunning ? "\(snapshot.activeConnections) / \(min(snapshot.adaptiveLimit, max(snapshot.concurrency, 1)))" : "0",
                             symbol: "point.3.connected.trianglepath.dotted")
                    StatTile(title: String(localized: "Retry queue"), value: "\(snapshot.waitingRetryAssets + snapshot.waitingRetryChunks)", symbol: "arrow.clockwise")
                    StatTile(title: String(localized: "Server-deferred"), value: "\(snapshot.deferredByServer)", symbol: "hourglass")
                }
            }
        }
    }

    @ViewBuilder
    private func pressureCard(_ snapshot: SyncSnapshot) -> some View {
        if let until = snapshot.serverBusyUntil, until > Date() {
            GlassCard {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "Server asked to slow down"), systemImage: "tortoise.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warning)
                    Text(String(localized: "Uploads resume automatically at \(until.formatted(date: .omitted, time: .standard)). Nothing is lost and no retry attempts are used."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = snapshot.serverBusyReason {
                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func backgroundCard(_ snapshot: SyncSnapshot, sync: SyncController) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(sync.settings.backgroundSync ? String(localized: "Background backup on") : String(localized: "Background backup off"),
                      systemImage: sync.settings.backgroundSync ? "moon.stars.fill" : "moon.zzz")
                    .font(.subheadline.weight(.semibold))
                if let last = snapshot.lastBackgroundHandoff {
                    Text(String(localized: "Last hand-off to iOS: \(snapshot.backgroundHandoff) chunks at \(last.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(localized: "When you leave the app, prepared encrypted chunks are handed to iOS, which keeps uploading them while the app is suspended. iOS decides when background time is granted. Swiping the app away in the app switcher stops background uploads until you open it again."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func conditionsCard(_ sync: SyncController) -> some View {
        let decision = sync.decision
        let conditions = sync.conditions
        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                if let reason = decision.blockReason {
                    Label(reason, systemImage: "pause.circle").foregroundStyle(Theme.warning).font(.subheadline.weight(.semibold))
                } else {
                    Label(String(localized: "\(decision.concurrency) parallel uploads"), systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                }
                HStack(spacing: 14) {
                    Label(conditions.network.isWiFi ? "Wi‑Fi" : (conditions.network.isCellular ? String(localized: "Cellular") : String(localized: "Offline")),
                          systemImage: conditions.network.isWiFi ? "wifi" : "antenna.radiowaves.left.and.right")
                    Label(conditions.isCharging ? String(localized: "Charging") : "\(Int(max(conditions.batteryLevel, 0) * 100))%", systemImage: conditions.isCharging ? "battery.100.bolt" : "battery.50")
                    Label(conditions.thermalTitle, systemImage: "thermometer.medium")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let free = AppDirectories.availableDeviceCapacity() {
                    Text(String(localized: "iPhone free space: \(Formatters.bytes(free))")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.configuration?.serverURL.host ?? "—", systemImage: "server.rack").font(.subheadline.weight(.semibold))
                if let account = model.account {
                    Text(String(localized: "\(account.itemCount) items · \(Formatters.bytes(account.storedBytes)) stored · \(Formatters.bytes(account.diskFreeBytes)) free"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(localized: "Folder: iphone-backups/\(model.configuration?.username ?? "")/\(model.configuration?.collection ?? "")"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ActiveTransferRow: View {
    let transfer: ActiveTransfer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(transfer.name).font(.subheadline).lineLimit(1)
                Spacer()
                Text(transfer.stage.title).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: transfer.fraction).tint(Theme.accent)
            if transfer.totalBytes > 0 {
                Text("\(Formatters.bytes(min(transfer.sentBytes, transfer.totalBytes))) / \(Formatters.bytes(transfer.totalBytes))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
