import Photos
import SwiftUI

/// The iPhone's own photo library (PhotoKit), with a badge for items already in the vault.
struct DeviceLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var viewerIndex: DeviceViewerStart?

    struct DeviceViewerStart: Identifiable { let id: Int }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: env.settings.gridColumns)
    }

    var body: some View {
        let photos = env.photos
        Group {
            switch photos.authorization {
            case .notDetermined:
                PermissionCard(
                    symbol: "photo.on.rectangle.angled",
                    title: String(localized: "Allow Photo Access"),
                    message: String(localized: "WezCrypt reads your photos and videos to back them up to your private vault. Nothing is deleted from your iPhone."),
                    actionTitle: String(localized: "Continue")
                ) {
                    Task { await photos.requestAccess() }
                }
            case .denied, .restricted:
                PermissionCard(
                    symbol: "lock.slash",
                    title: String(localized: "Photo Access Is Off"),
                    message: String(localized: "Turn on Photos access for WezCrypt in Settings to view and sync your library."),
                    actionTitle: String(localized: "Open Settings")
                ) {
                    photos.openSystemSettings()
                }
            default:
                grid(photos)
            }
        }
        .task {
            photos.refreshAuthorization()
            await env.sync.reloadCompletedIDs()
        }
        .fullScreenCover(item: $viewerIndex) { start in
            DeviceAssetViewer(startIndex: start.id)
        }
    }

    private func grid(_ photos: PhotoLibraryService) -> some View {
        ScrollView {
            if photos.isLimited {
                LimitedAccessBanner()
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<photos.assets.count, id: \.self) { index in
                    let asset = photos.assets.object(at: index)
                    DeviceAssetCell(asset: asset, isSynced: env.sync.completedLocalIDs.contains(asset.localIdentifier))
                        .onTapGesture { viewerIndex = DeviceViewerStart(id: index) }
                }
            }
            Text(String(localized: "\(photos.assets.count) items on this iPhone · \(env.sync.completedLocalIDs.count) in vault"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
        }
        .overlay {
            if photos.assets.count == 0 {
                ContentUnavailableView(String(localized: "No Photos"), systemImage: "photo", description: Text(String(localized: "Photos and videos on this iPhone appear here.")))
            }
        }
    }
}

struct PermissionCard: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LimitedAccessBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "Limited Access"), systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "Only the photos you selected are visible to WezCrypt. Sync All can only back up those items."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Manage Selection")) { env.photos.presentLimitedLibraryPicker() }
                    Spacer()
                    Button(String(localized: "Allow Full Access")) { env.photos.openSystemSettings() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }
}

struct DeviceAssetCell: View {
    let asset: PHAsset
    let isSynced: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.placeholder
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(Formatters.duration(asset.duration))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSynced {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.caption)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .shadow(radius: 2)
                        .padding(5)
                        .accessibilityLabel(String(localized: "In vault"))
                }
            }
            .task(id: asset.localIdentifier) {
                let side = proxy.size.width * displayScale
                image = await LocalImageRequester.image(for: asset, targetSize: CGSize(width: side, height: side))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(asset.mediaType == .video ? String(localized: "Video") : String(localized: "Photo"))
        .accessibilityValue(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
        .accessibilityAddTraits(.isButton)
    }
}

/// Full-screen viewer for on-device assets.
struct DeviceAssetViewer: View {
    let startIndex: Int
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true

    init(startIndex: Int) {
        self.startIndex = startIndex
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(0..<env.photos.assets.count, id: \.self) { position in
                    DeviceAssetPage(asset: env.photos.assets.object(at: position), isActive: position == index, chromeVisible: $chromeVisible)
                        .tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if chromeVisible {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.headline)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(String(localized: "Close"))
                        Spacer()
                        if let date = env.photos.asset(at: index)?.creationDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        }
                        Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                    .padding()
                    Spacer()
                }
                .foregroundStyle(.white)
            }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(.dark)
    }
}

private struct DeviceAssetPage: View {
    let asset: PHAsset
    let isActive: Bool
    @Binding var chromeVisible: Bool
    @State private var image: UIImage?
    @State private var player: VideoPlayerModel?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayerView(model: player, controlsVisible: $chromeVisible)
            } else if let image {
                ZoomableImageView(image: image, onSingleTap: { withAnimation { chromeVisible.toggle() } })
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                player?.teardown()
                player = nil
                return
            }
            if asset.mediaType == .video {
                if let item = try? await LocalImageRequester.playerItem(for: asset) {
                    let model = VideoPlayerModel()
                    model.load(playerItem: item, autoplay: true)
                    player = model
                }
            } else {
                let screen = UIScreen.main.bounds.size
                let scale = UIScreen.main.scale
                image = await LocalImageRequester.image(
                    for: asset,
                    targetSize: CGSize(width: screen.width * scale * 2, height: screen.height * scale * 2),
                    contentMode: .aspectFit,
                    highQuality: true
                )
            }
        }
        .onDisappear {
            player?.teardown()
            player = nil
        }
    }
}
