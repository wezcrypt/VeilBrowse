import Photos
import SwiftUI

/// Backup Progress and Failed Transfers.
struct TransfersView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case queued, active, completed, failed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .queued: return String(localized: "Waiting")
            case .active: return String(localized: "Active")
            case .completed: return String(localized: "Done")
            case .failed: return String(localized: "Failed")
            }
        }

        var states: [AssetState] {
            switch self {
            case .queued: return [.pending]
            case .active: return [.preparing, .uploading, .finalizing]
            case .completed: return [.completed, .duplicate]
            case .failed: return [.failed]
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var segment: Segment = .active
    @State private var assets: [QueueAsset] = []
    @State private var canLoadMore = false
    private let pageSize = 150

    var body: some View {
        let sync = model.sync
        NavigationStack {
            List {
                Section {
                    Picker(String(localized: "Status"), selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if segment == .active && !sync.snapshot.active.isEmpty {
                    Section(String(localized: "Live")) {
                        ForEach(sync.snapshot.active) { ActiveTransferRow(transfer: $0) }
                    }
                }
                if segment == .failed && sync.snapshot.counts.failed > 0 {
                    Section {
                        Button { sync.retryFailed() } label: { Label(String(localized: "Retry All Failed"), systemImage: "arrow.clockwise") }
                    }
                }
                Section {
                    if assets.isEmpty {
                        Text(emptyText).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    ForEach(assets) { asset in
                        QueueRow(asset: asset)
                            .swipeActions {
                                if asset.state == .failed {
                                    Button { sync.retry(asset) } label: { Label(String(localized: "Retry"), systemImage: "arrow.clockwise") }.tint(Theme.accent)
                                }
                            }
                    }
                    if canLoadMore {
                        Button(String(localized: "Load More")) { Task { await load(reset: false) } }.frame(maxWidth: .infinity)
                    }
                } header: {
                    Text(String(localized: "\(sync.snapshot.counts.completed) done · \(sync.snapshot.counts.remaining) remaining · \(sync.snapshot.counts.failed) failed"))
                }
            }
            .navigationTitle(String(localized: "Transfers"))
            .refreshable { await sync.refresh(); await load(reset: true) }
            .task(id: reloadKey) { await load(reset: true) }
        }
    }

    private var reloadKey: String {
        let c = model.sync.snapshot.counts
        return "\(segment.rawValue)-\(c.pending)-\(c.active)-\(c.completed)-\(c.failed)"
    }

    private var emptyText: String {
        switch segment {
        case .queued: return String(localized: "Nothing waiting.")
        case .active: return String(localized: "No transfers in progress.")
        case .completed: return String(localized: "Backed-up items appear here.")
        case .failed: return String(localized: "No failed transfers.")
        }
    }

    private func load(reset: Bool) async {
        let page = await model.sync.assets(segment.states, limit: pageSize, offset: reset ? 0 : assets.count)
        assets = reset ? page : assets + page
        canLoadMore = page.count == pageSize
    }
}

private struct QueueRow: View {
    let asset: QueueAsset
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.placeholder
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() } else {
                    Image(systemName: asset.kind.symbol).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.displayName ?? asset.kind.title).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(asset.state.title)
                    if let bytes = asset.totalBytes { Text("· \(Formatters.bytes(bytes))") }
                    if asset.attempts > 0 && asset.state != .completed { Text(String(localized: "· attempt \(asset.attempts)")) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let error = asset.lastError, asset.state != .completed && asset.state != .duplicate {
                    Text(error).font(.caption2).foregroundStyle(asset.state == .failed ? Theme.danger : Theme.warning).lineLimit(3)
                }
            }
        }
        .task(id: asset.localID) {
            guard asset.source == .photos, let item = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localID], options: nil).firstObject else { return }
            thumbnail = await LocalThumbnail.image(for: item, side: 138)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small async wrapper around PHImageManager for list thumbnails.
@MainActor
enum LocalThumbnail {
    static func image(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let result: UncheckedSendable<UIImage?> = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { @Sendable image, _ in
                continuation.resume(returning: UncheckedSendable(image))
            }
        }
        return result.value
    }
}
