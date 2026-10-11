import SwiftUI

/// Full-screen pager over the items of a vault query: swipe between items,
/// pinch to zoom photos, stream videos.
struct MediaViewer: View {
    let model: VaultLibraryModel
    var album: Album?
    @State private var currentID: String
    @State private var chromeVisible = true
    @State private var isZoomed = false
    @State private var showInfo = false
    @State private var showAlbumPicker = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env

    init(model: VaultLibraryModel, startID: String, album: Album? = nil) {
        self.model = model
        self.album = album
        _currentID = State(initialValue: startID)
    }

    private var currentItem: MediaItem? { model.item(id: currentID) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(model.items) { item in
                    MediaPage(item: item, isActive: item.id == currentID, chromeVisible: $chromeVisible, isZoomed: $isZoomed)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .scrollDisabled(isZoomed)

            if chromeVisible {
                chrome.transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(.dark)
        .onChange(of: currentID) { _, newValue in
            isZoomed = false
            if let item = model.item(id: newValue) {
                Task { await model.loadMoreIfNeeded(current: item) }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let item = currentItem {
                MediaInfoSheet(item: item)
            }
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerSheet(mediaIDs: [currentID]) {}
        }
        .confirmationDialog(String(localized: "Delete this item from the vault?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete Permanently"), role: .destructive) { Task { await deleteCurrent() } }
        } message: {
            Text(String(localized: "The encrypted copy on the server is removed. Photos on this iPhone are not affected."))
        }
        .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var chrome: some View {
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
                if let item = currentItem {
                    VStack(spacing: 2) {
                        Text(item.takenAt.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                        Text(item.takenAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
            HStack {
                Button { Task { await toggleFavorite() } } label: {
                    Image(systemName: currentItem?.isFavorite == true ? "heart.fill" : "heart")
                }
                .accessibilityLabel(currentItem?.isFavorite == true ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel(String(localized: "Info"))
                Spacer()
                Button { showAlbumPicker = true } label: { Image(systemName: "rectangle.stack.badge.plus") }
                    .accessibilityLabel(String(localized: "Add to Album"))
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel(String(localized: "Delete"))
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func toggleFavorite() async {
        guard var item = currentItem else { return }
        do {
            item = try await env.api.updateMedia(item.id, isFavorite: !item.isFavorite)
            model.replace(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrent() async {
        guard let item = currentItem else { return }
        let items = model.items
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        do {
            _ = try await env.api.deleteMedia([item.id])
            await env.images.evict([item.id])
            let next = items.indices.contains(index + 1) ? items[index + 1].id : (index > 0 ? items[index - 1].id : nil)
            model.remove(ids: [item.id])
            if let next {
                currentID = next
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MediaPage: View {
    let item: MediaItem
    let isActive: Bool
    @Binding var chromeVisible: Bool
    @Binding var isZoomed: Bool

    var body: some View {
        if item.isVideo {
            VideoPage(item: item, isActive: isActive, chromeVisible: $chromeVisible)
        } else {
            PhotoPage(item: item, isActive: isActive, chromeVisible: $chromeVisible, isZoomed: $isZoomed)
        }
    }
}

private struct PhotoPage: View {
    let item: MediaItem
    let isActive: Bool
    @Binding var chromeVisible: Bool
    @Binding var isZoomed: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var preview: UIImage?
    @State private var fullImage: UIImage?
    @State private var loadError: String?
    @State private var isLoadingFull = false

    var body: some View {
        ZStack {
            if let image = fullImage ?? preview {
                ZoomableImageView(
                    image: image,
                    onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } },
                    onZoomChange: { zoomed in if isActive { isZoomed = zoomed } }
                )
                .ignoresSafeArea()
                .accessibilityLabel(item.filename)
            }
            if isLoadingFull && fullImage == nil {
                ProgressView().tint(.white)
            }
            if let loadError, fullImage == nil {
                VStack {
                    Spacer()
                    ErrorBanner(message: loadError) { Task { await loadFull() } }
                        .padding()
                        .padding(.bottom, 80)
                }
            }
        }
        .task(id: item.id) {
            if preview == nil {
                preview = env.images.cachedThumbnail(item.id)
                if preview == nil {
                    preview = await env.images.thumbnail(for: item, pixelSize: 512)
                }
            }
        }
        .task(id: isActive) {
            if isActive, fullImage == nil { await loadFull() }
        }
        .onChange(of: isActive) { _, active in
            // Release full-resolution bitmaps of pages that are no longer visible.
            if !active { fullImage = nil }
        }
    }

    private func loadFull() async {
        guard !isLoadingFull else { return }
        isLoadingFull = true
        loadError = nil
        defer { isLoadingFull = false }
        do {
            let fileURL = try await env.api.downloadContent(item.id)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let screen = UIScreen.main.bounds.size
            let maxPixel = max(screen.width, screen.height) * UIScreen.main.scale * 2
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.downsample(fileURL: fileURL, maxPixelSize: maxPixel)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                fullImage = decoded
            } else {
                loadError = String(localized: "This image format can’t be displayed on this iPhone.")
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct VideoPage: View {
    let item: MediaItem
    let isActive: Bool
    @Binding var chromeVisible: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var model: VideoPlayerModel?
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let model {
                VideoPlayerView(model: model, controlsVisible: $chromeVisible)
            } else {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFit()
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 8)
            }
        }
        .task(id: item.id) {
            poster = await env.images.thumbnail(for: item, pixelSize: 512)
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                let player = VideoPlayerModel()
                player.loadRemote(item, api: env.api, autoplay: true)
                model = player
            } else {
                model?.teardown()
                model = nil
            }
        }
        .onDisappear {
            model?.teardown()
            model = nil
        }
    }
}

struct MediaInfoSheet: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State private var details: MediaItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(String(localized: "Name"), value: shown.filename)
                    LabeledContent(String(localized: "Size"), value: Formatters.bytes(shown.sizeBytes))
                    LabeledContent(String(localized: "Date"), value: shown.takenAt.formatted(date: .long, time: .shortened))
                    LabeledContent(String(localized: "Added"), value: shown.addedAt.formatted(date: .long, time: .shortened))
                    LabeledContent(String(localized: "Type"), value: "\(shown.isVideo ? String(localized: "Video") : String(localized: "Photo")) · \(shown.mimeType)")
                    if let dimensions = Formatters.dimensions(width: shown.width, height: shown.height) {
                        LabeledContent(String(localized: "Dimensions"), value: dimensions)
                    }
                    if let duration = shown.duration {
                        LabeledContent(String(localized: "Duration"), value: Formatters.duration(duration))
                    }
                    if let albums = shown.albumIds {
                        LabeledContent(String(localized: "Albums"), value: String(albums.count))
                    }
                }
                Section(String(localized: "Security")) {
                    LabeledContent(String(localized: "Storage"), value: shown.storageKind == "wzc2" ? "WZC2 · AES-256-GCM" : "WZC1 · AES-GCM")
                    LabeledContent("SHA-256") {
                        Text(shown.sha256.hasPrefix("legacy:") ? "—" : String(shown.sha256.prefix(16)) + "…")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(String(localized: "Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task { details = try? await env.api.media(item.id) }
        }
        .presentationDetents([.medium, .large])
    }

    private var shown: MediaItem { details ?? item }
}
