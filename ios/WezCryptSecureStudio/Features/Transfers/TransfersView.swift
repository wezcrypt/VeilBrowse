import Photos
import SwiftUI

struct TransfersView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var segment: SyncState = .pending
    @State private var records: [SyncRecord] = []
    @State private var canLoadMore = false
    @State private var isLoadingRecords = false
    private let pageSize = 150

    var body: some View {
        let sync = env.sync
        NavigationStack {
            List {
                Section {
                    SyncHeaderCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker(String(localized: "Status"), selection: $segment) {
                        ForEach(SyncState.allCases) { state in
                            Text("\(state.title) \(sync.snapshot.counts.count(for: state))").tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if segment == .failed, sync.snapshot.counts.failed > 0 {
                    Section {
                        Button {
                            sync.retryFailed()
                        } label: {
                            Label(String(localized: "Retry All Failed"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                if segment == .uploading, !sync.snapshot.active.isEmpty {
                    Section(String(localized: "In Progress")) {
                        ForEach(sync.snapshot.active) { item in
                            ActiveUploadRow(item: item)
                        }
                    }
                }
                Section {
                    if records.isEmpty && !isLoadingRecords {
                        Text(emptyText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                    ForEach(records) { record in
                        TransferRow(record: record)
                            .swipeActions {
                                if record.state == .failed {
                                    Button { sync.retry(record) } label: { Label(String(localized: "Retry"), systemImage: "arrow.clockwise") }
                                        .tint(Theme.accent)
                                }
                            }
                    }
                    if canLoadMore {
                        Button(String(localized: "Load More")) { Task { await loadRecords(reset: false) } }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(String(localized: "Transfers"))
            .refreshable {
                await sync.refreshCounts()
                await loadRecords(reset: true)
            }
            .task(id: reloadKey) { await loadRecords(reset: true) }
            .task { await sync.refreshCounts() }
        }
    }

    /// Reload the list when the segment changes or items move between states.
    private var reloadKey: String {
        let counts = env.sync.snapshot.counts
        return "\(segment.rawValue)-\(counts.pending)-\(counts.uploading)-\(counts.completed)-\(counts.failed)"
    }

    private var emptyText: String {
        switch segment {
        case .pending: return String(localized: "Nothing waiting. Tap Sync All to scan your library.")
        case .uploading: return String(localized: "No uploads in progress.")
        case .completed: return String(localized: "Uploaded items appear here.")
        case .failed: return String(localized: "No failed uploads.")
        }
    }

    private func loadRecords(reset: Bool) async {
        isLoadingRecords = true
        defer { isLoadingRecords = false }
        let offset = reset ? 0 : records.count
        let page = await env.sync.records(for: segment, limit: pageSize, offset: offset)
        records = reset ? page : records + page
        canLoadMore = page.count == pageSize
    }
}

struct SyncHeaderCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let sync = env.sync
        let snapshot = sync.snapshot
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Library Sync")).font(.title3.bold())
                    Text(sync.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if snapshot.isRunning {
                    ProgressView()
                }
            }

            ProgressView(value: sync.overallProgress)
                .tint(Theme.accent)
                .accessibilityLabel(String(localized: "Overall progress"))
                .accessibilityValue(Text(sync.overallProgress, format: .percent.precision(.fractionLength(0))))

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    StatTile(title: String(localized: "Speed"), value: Formatters.speed(snapshot.bytesPerSecond), symbol: "speedometer")
                    StatTile(title: String(localized: "Time Left"), value: snapshot.isRunning ? Formatters.eta(snapshot.etaSeconds) : "—", symbol: "clock")
                }
                GridRow {
                    StatTile(title: String(localized: "Remaining"), value: "\(snapshot.counts.remaining) · \(Formatters.bytes(snapshot.remainingBytesEstimate))", symbol: "tray.full")
                    StatTile(title: String(localized: "iPhone Free Space"), value: sync.deviceFreeSpace.map(Formatters.bytes) ?? "—", symbol: "internaldrive")
                }
                GridRow {
                    StatTile(title: String(localized: "Uploaded"), value: "\(snapshot.counts.completed)", symbol: "checkmark.icloud")
                    StatTile(title: String(localized: "This Session"), value: Formatters.bytes(snapshot.sessionUploadedBytes), symbol: "arrow.up.circle")
                }
            }

            networkHint

            if snapshot.phase == .needsPermission {
                Button(String(localized: "Allow Photo Access")) {
                    Task {
                        await env.photos.requestAccess()
                        if !env.photos.hasAccess { env.photos.openSystemSettings() }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            HStack(spacing: 12) {
                if snapshot.isRunning {
                    Button {
                        sync.pause()
                    } label: {
                        Label(String(localized: "Pause"), systemImage: "pause.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button {
                        sync.syncAll()
                    } label: {
                        Label(String(localized: "Sync All"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityHint(String(localized: "Scans your whole photo library and uploads everything not yet in the vault."))
                    if snapshot.phase == .paused || snapshot.counts.remaining > 0 {
                        Button {
                            sync.resume()
                        } label: {
                            Label(String(localized: "Resume"), systemImage: "play.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.vertical, 4)
        .onAppear { sync.refreshDeviceSpace() }
    }

    @ViewBuilder
    private var networkHint: some View {
        let status = env.sync.networkStatus
        let policy = env.settings.syncPolicy
        if let reason = status.blockReason(policy) {
            Label(reason, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
        } else {
            Label(
                env.settings.networkMode == .wifiOnly ? String(localized: "Uploading over Wi‑Fi only") : String(localized: "Uploading over Wi‑Fi and cellular"),
                systemImage: status.isWiFi ? "wifi" : "antenna.radiowaves.left.and.right"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ActiveUploadRow: View {
    let item: ActiveUpload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.filename ?? String(localized: "Preparing…")).font(.subheadline).lineLimit(1)
                Spacer()
                Text(item.stage.title).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: item.fraction).tint(Theme.accent)
            if item.totalBytes > 0 {
                Text("\(Formatters.bytes(item.sentBytes)) / \(Formatters.bytes(item.totalBytes))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct TransferRow: View {
    let record: SyncRecord
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.placeholder
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: record.kind == .video ? "video" : "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.filename ?? (record.kind == .video ? String(localized: "Video") : String(localized: "Photo")))
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let created = record.createdAt {
                        Text(created.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let bytes = record.bytes {
                        Text("· \(Formatters.bytes(bytes))")
                    }
                    if record.attempts > 0 && record.state != .completed {
                        Text(String(localized: "· attempt \(record.attempts)"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = record.lastError, record.state != .completed {
                    Text(error).font(.caption2).foregroundStyle(record.state == .failed ? Theme.danger : Theme.warning).lineLimit(2)
                }
            }
            Spacer()
            stateIcon
        }
        .task(id: record.localID) {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [record.localID], options: nil)
            if let asset = fetch.firstObject {
                thumbnail = await LocalImageRequester.image(for: asset, targetSize: CGSize(width: 144, height: 144))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch record.state {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .uploading: Image(systemName: "arrow.up.circle").foregroundStyle(Theme.accent)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
        }
    }
}
