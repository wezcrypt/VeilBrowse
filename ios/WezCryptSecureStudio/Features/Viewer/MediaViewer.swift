import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the grid asks the viewer to show.
struct ViewerRequest: Identifiable {
    let id = UUID()
    let kinds: Set<ItemKind>
    let startID: String
}

/// Full-screen viewer for backed-up photos and videos: black background, swipe
/// between items, pinch / double-tap zoom, tap to hide the controls, details,
/// share and save to Photos. Everything is decrypted on this iPhone; the server
/// only ever sends ciphertext.
struct MediaViewer: View {
    let kinds: Set<ItemKind>
    let library: VaultLibraryModel
    var onReachEnd: () async -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var chromeVisible = true
    @State private var showInfo = false
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var busy = false
    @State private var banner: Banner?
    @State private var confirmDelete = false

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    init(kinds: Set<ItemKind>, startID: String, library: VaultLibraryModel, onReachEnd: @escaping () async -> Void = {}) {
        self.kinds = kinds
        self.library = library
        self.onReachEnd = onReachEnd
        _selection = State(initialValue: startID)
    }

    /// Live view of the library (pages loaded while viewing appear automatically).
    private var items: [VaultItem] { library.items.filter { kinds.contains($0.kind) } }
    private var index: Int { items.firstIndex { $0.id == selection } ?? 0 }
    private var current: VaultItem? { items.first { $0.id == selection } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(items) { item in
                    page(for: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                chrome.transition(.opacity)
            }
            if let banner {
                VStack {
                    Spacer()
                    Text(banner.text)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(banner.isError ? Color.red.opacity(0.85) : Color.black.opacity(0.8), in: Capsule())
                        .padding(.bottom, 110)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInfo) {
            if let current { MediaInfoSheet(item: current).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $showShare, onDismiss: cleanupShare) { ShareSheet(items: shareURLs) }
        .confirmationDialog(String(localized: "Delete this backup permanently?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await deleteCurrent() } }
        } message: {
            Text(String(localized: "The encrypted copy is removed from the server. Photos on this iPhone are not affected."))
        }
        .task(id: selection) {
            if index >= items.count - 5 { await onReachEnd() }
        }
    }

    @ViewBuilder
    private func page(for item: VaultItem) -> some View {
        let isCurrent = item.id == selection
        if item.kind == .video {
            VideoPage(item: item, isCurrent: isCurrent, chromeVisible: $chromeVisible,
                      hasPrevious: index > 0, hasNext: index < items.count - 1,
                      onPrevious: { move(by: -1) }, onNext: { move(by: 1) })
        } else {
            PhotoPage(item: item, isCurrent: isCurrent, chromeVisible: $chromeVisible, library: library)
        }
    }

    private func move(by offset: Int) {
        let target = index + offset
        guard items.indices.contains(target) else { return }
        withAnimation { selection = items[target].id }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(String(localized: "Close"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let current {
                        Text("\(current.date.formatted(date: .abbreviated, time: .shortened)) · \(index + 1) / \(items.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().tint(.white) }
                if current?.kind == .video {
                    // Videos keep the bottom of the screen for the player controls.
                    toolbarButton("square.and.arrow.up", String(localized: "Share")) { Task { await share() } }
                    toolbarButton("photo.badge.arrow.down", String(localized: "Save to Photos")) { Task { await saveToPhotos() } }
                    toolbarButton("info.circle", String(localized: "Info")) { showInfo = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top))

            Spacer()

            if current?.kind != .video {
                HStack {
                    toolbarButton("square.and.arrow.up", String(localized: "Share")) { Task { await share() } }
                    Spacer()
                    toolbarButton("photo.badge.arrow.down", String(localized: "Save to Photos")) { Task { await saveToPhotos() } }
                    Spacer()
                    toolbarButton("info.circle", String(localized: "Info")) { showInfo = true }
                    Spacer()
                    toolbarButton("trash", String(localized: "Delete")) { confirmDelete = true }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom))
            }
        }
        .foregroundStyle(.white)
        .disabled(busy)
    }

    private func toolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel(title)
    }

    // MARK: Actions

    private func share() async {
        guard let current else { return }
        busy = true
        defer { busy = false }
        do {
            shareURLs = try await model.restoreService().decryptForExport(current)
            showShare = true
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func saveToPhotos() async {
        guard let current else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.restoreService().restoreToPhotos(current)
            show(String(localized: "Saved to Photos (original, verified)."), isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func deleteCurrent() async {
        guard let current else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.api?.deleteItem(current.id)
            library.remove(current)
            dismiss()
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        withAnimation { banner = Banner(text: text, isError: isError) }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { banner = nil }
        }
    }

    private func cleanupShare() {
        if let folder = shareURLs.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        shareURLs = []
    }
}

// MARK: - Photo page

/// One photo: shows the cached thumbnail instantly, then the decrypted original
/// decoded at screen resolution; zooming in re-decodes at up to 5,000 px so fine
/// detail is visible without holding a full-size bitmap for every page. The
/// original bytes (used for sharing and saving) are never recompressed.
struct PhotoPage: View {
    let item: VaultItem
    let isCurrent: Bool
    @Binding var chromeVisible: Bool
    let library: VaultLibraryModel

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var isPreview = true
    @State private var fileURL: URL?
    @State private var progress: Double?
    @State private var error: String?
    @State private var detailed = false
    @State private var livePhoto: UncheckedSendable<PHLivePhoto>?
    @State private var liveLoading = false
    @State private var showLive = false
    @State private var loadTask: Task<Void, Never>?

    private static let detailMaxPixels: CGFloat = 5000

    var body: some View {
        ZStack {
            Color.black
            if showLive, let livePhoto {
                LivePhotoView(livePhoto: livePhoto.value)
                    .onTapGesture { showLive = false }
            } else if let image {
                ZoomableImageView(image: image, onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                }, onZoomChange: { zoomed in
                    if zoomed { loadDetail() }
                })
                .overlay(alignment: .bottom) {
                    if let progress, isPreview {
                        ProgressView(value: progress).tint(.white).frame(width: 160).padding(.bottom, 120)
                    }
                }
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.white)
                    Button(String(localized: "Try Again")) { start() }.buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.kind == .livePhoto, chromeVisible {
                Button { Task { await playLive() } } label: {
                    HStack(spacing: 4) {
                        if liveLoading { ProgressView().controlSize(.mini).tint(.white) } else { Image(systemName: "livephoto") }
                        Text("LIVE").font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.top, 70).padding(.leading, 16)
                .accessibilityLabel(String(localized: "Play Live Photo"))
            }
        }
        .onAppear { if image == nil || isPreview { start() } }
        .onDisappear(perform: cleanup)
    }

    private func start() {
        loadTask?.cancel()
        error = nil
        loadTask = Task { await load() }
    }

    private func load() async {
        if image == nil, let thumbnail = await library.thumbnail(for: item, model: model) {
            image = thumbnail
        }
        guard let primary = item.manifest.primary else { error = RestoreError.missingResource.localizedDescription; return }
        do {
            let service = try model.restoreService()
            let box = LockedBox(0.0)
            progress = 0
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    progress = box.value
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { ticker.cancel() }
            let url = try await service.viewerFile(primary) { box.value = $0 }
            try Task.checkCancellation()
            fileURL = url
            let screen = UIScreen.main.bounds.size
            let maxPixel = max(screen.width, screen.height) * UIScreen.main.scale * 1.5
            let decoded = await Task.detached(priority: .userInitiated) { ImageDownsampler.downsample(fileURL: url, maxPixelSize: maxPixel) }.value
            try Task.checkCancellation()
            guard let decoded else {
                if image == nil || isPreview { error = String(localized: "This image format cannot be displayed on iOS. Use Share or Save to keep the original.") }
                return
            }
            image = decoded
            isPreview = false
            progress = nil
        } catch is CancellationError {
            return
        } catch {
            progress = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Higher-resolution decode once the user zooms in (bounded to 5,000 px).
    private func loadDetail() {
        guard !detailed, let fileURL else { return }
        detailed = true
        let largest = CGFloat(max(item.manifest.pixelWidth ?? 0, item.manifest.pixelHeight ?? 0))
        let target = min(largest > 0 ? largest : Self.detailMaxPixels, Self.detailMaxPixels)
        Task {
            if let sharper = await Task.detached(priority: .userInitiated, operation: { ImageDownsampler.downsample(fileURL: fileURL, maxPixelSize: target) }).value,
               sharper.size.width * sharper.scale > (image?.size.width ?? 0) * (image?.scale ?? 1) {
                image = sharper
            }
        }
    }

    private func playLive() async {
        if livePhoto != nil { showLive = true; return }
        guard let photoURL = fileURL, let paired = item.manifest.resources.first(where: { $0.role == .pairedVideo }) else { return }
        liveLoading = true
        defer { liveLoading = false }
        do {
            let videoURL = try await model.restoreService().viewerFile(paired)
            let placeholder = image
            let result: UncheckedSendable<PHLivePhoto>? = await withCheckedContinuation { continuation in
                let resumed = LockedBox(false)
                PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL], placeholderImage: placeholder, targetSize: .zero, contentMode: .aspectFit) { live, info in
                    let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                    let cancelled = (info[PHLivePhotoInfoCancelledKey] as? Bool) ?? false
                    let failed = info[PHLivePhotoInfoErrorKey] != nil
                    let outcome: UncheckedSendable<PHLivePhoto>??
                    if let live, !degraded {
                        outcome = .some(UncheckedSendable(live))
                    } else if live == nil, !degraded || cancelled || failed {
                        outcome = .some(nil)
                    } else {
                        outcome = nil
                    }
                    guard let outcome else { return }
                    let first = resumed.withValue { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if first { continuation.resume(returning: outcome) }
                }
            }
            if let result {
                livePhoto = result
                showLive = true
            } else {
                error = String(localized: "The Live Photo could not be assembled from its backed-up photo and video.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        fileURL = nil
        detailed = false
        livePhoto = nil
        showLive = false
        // Keep only the small thumbnail in memory for pages that are off screen.
        if !isPreview { image = nil; isPreview = true }
    }
}

struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            view.startPlayback(with: .full)
        }
    }
}

// MARK: - Info

struct MediaInfoSheet: View {
    let item: VaultItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(String(localized: "Name"), value: item.name)
                    LabeledContent(String(localized: "Format"), value: Self.format(of: item))
                    LabeledContent(String(localized: "Size"), value: Formatters.bytes(item.manifest.payloadBytes))
                    if let dims = Formatters.dimensions(width: item.manifest.pixelWidth, height: item.manifest.pixelHeight) {
                        LabeledContent(String(localized: "Resolution"), value: dims)
                    }
                    LabeledContent(String(localized: "Date"), value: item.date.formatted(date: .long, time: .shortened))
                    if let duration = item.manifest.duration {
                        LabeledContent(String(localized: "Duration"), value: Formatters.duration(duration))
                    }
                    LabeledContent(String(localized: "Type"), value: item.kind.title)
                }
                Section(String(localized: "Stored Files")) {
                    ForEach(item.manifest.resources.filter { $0.role != .thumbnail }, id: \.objectId) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.filename)
                            Text("\(Self.roleTitle(resource.role)) · \(Formatters.bytes(resource.size))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Label(String(localized: "End-to-end encrypted. Decrypted only on this iPhone."), systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Info"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    static func format(of item: VaultItem) -> String {
        guard let primary = item.manifest.primary else { return "—" }
        let type = primary.uti.flatMap(UTType.init) ?? UTType(filenameExtension: (primary.filename as NSString).pathExtension)
        let ext = (primary.filename as NSString).pathExtension.uppercased()
        if let description = type?.localizedDescription, !ext.isEmpty { return "\(ext) — \(description)" }
        return ext.isEmpty ? (type?.localizedDescription ?? "—") : ext
    }

    static func roleTitle(_ role: ResourceRole) -> String {
        switch role {
        case .photo: return String(localized: "Original photo")
        case .alternatePhoto: return String(localized: "Alternate (RAW/JPEG pair)")
        case .pairedVideo: return String(localized: "Live Photo video")
        case .video: return String(localized: "Original video")
        case .file: return String(localized: "File")
        case .thumbnail: return String(localized: "Thumbnail")
        }
    }
}

// MARK: - Grid ↔ viewer transition (zoom on iOS 18, fade on iOS 17)

extension View {
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransitionDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
