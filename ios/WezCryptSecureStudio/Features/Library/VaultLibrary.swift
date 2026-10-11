import AVKit
import Observation
import SwiftUI

/// Pages through the encrypted catalog on the server and decrypts manifests locally.
@MainActor
@Observable
final class VaultLibraryModel {
    private(set) var items: [VaultItem] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var undecryptable = 0
    private(set) var error: String?
    private var cursor: String?
    private var thumbnails: [String: UIImage] = [:]
    private var thumbnailTasks: [String: Task<UIImage?, Never>] = [:]

    var media: [VaultItem] { items.filter { $0.kind != .file } }
    var files: [VaultItem] { items.filter { $0.kind == .file } }

    func reload(_ model: AppModel) async {
        cursor = nil
        reachedEnd = false
        items = []
        undecryptable = 0
        await loadMore(model)
    }

    func loadMore(_ model: AppModel) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let service = try model.restoreService()
            let page = try await service.page(cursor: cursor)
            items += page.items
            undecryptable += page.failures
            cursor = page.next
            reachedEnd = page.next == nil
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func thumbnail(for item: VaultItem, model: AppModel) async -> UIImage? {
        if let cached = thumbnails[item.id] { return cached }
        if let task = thumbnailTasks[item.id] { return await task.value }
        guard let service = try? model.restoreService() else { return nil }
        let task = Task { try? await service.thumbnail(for: item) }
        thumbnailTasks[item.id] = task
        let image = await task.value
        thumbnailTasks[item.id] = nil
        if let image {
            if thumbnails.count > 600 { thumbnails.removeAll() }
            thumbnails[item.id] = image
        }
        return image
    }

    func remove(_ item: VaultItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
    }
}

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case media, files
        var id: String { rawValue }
        var title: String { self == .media ? String(localized: "Photos & Videos") : String(localized: "Files") }
    }

    @Environment(AppModel.self) private var model
    @State private var library = VaultLibraryModel()
    @State private var section: Section = .media
    @State private var showRestore = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if section == .media { mediaGrid } else { fileList }
            }
            .overlay {
                if !library.isLoading && library.items.isEmpty && library.error == nil {
                    ContentUnavailableView(String(localized: "No Backups Yet"), systemImage: "lock.shield",
                                           description: Text(String(localized: "Backed-up items appear here, decrypted on this iPhone only.")))
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    Picker(String(localized: "Section"), selection: $section) {
                        ForEach(Section.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let error = library.error { ErrorBanner(message: error) { Task { await library.reload(model) } } }
                    if library.undecryptable > 0 {
                        Text(String(localized: "\(library.undecryptable) items could not be decrypted with this recovery key."))
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle(String(localized: "Library"))
            .navigationDestination(for: VaultItem.ID.self) { id in
                if let item = library.items.first(where: { $0.id == id }) {
                    ItemDetailView(item: item, library: library)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showRestore = true } label: { Label(String(localized: "Restore"), systemImage: "arrow.down.circle") }
                }
            }
            .sheet(isPresented: $showRestore) { RestoreView(library: library) }
            .refreshable { await library.reload(model) }
            .task { if library.items.isEmpty { await library.reload(model) } }
        }
    }

    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.media) { item in
                    NavigationLink(value: item.id) {
                        VaultThumbnail(item: item, library: library)
                    }
                    .buttonStyle(.plain)
                    .task { if item.id == library.media.last?.id { await library.loadMore(model) } }
                }
            }
            if library.isLoading { ProgressView().padding() }
        }
    }

    private var fileList: some View {
        List {
            ForEach(library.files) { item in
                NavigationLink(value: item.id) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            Text("\(Formatters.bytes(item.manifest.payloadBytes)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .task { if item.id == library.files.last?.id { await library.loadMore(model) } }
            }
            if library.isLoading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
    }
}

struct VaultThumbnail: View {
    let item: VaultItem
    let library: VaultLibraryModel
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.placeholder
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = item.manifest.duration {
                    Text(Formatters.duration(duration)).font(.caption2.bold().monospacedDigit()).foregroundStyle(.white).shadow(radius: 2).padding(4)
                } else if item.kind == .livePhoto {
                    Image(systemName: "livephoto").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .task(id: item.id) { image = await library.thumbnail(for: item, model: model) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("\(item.kind.title), \(item.date.formatted(date: .abbreviated, time: .shortened))")
    }
}

struct ItemDetailView: View {
    let item: VaultItem
    let library: VaultLibraryModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var tempFolder: URL?
    @State private var loading = false
    @State private var status: String?
    @State private var error: String?
    @State private var exportURLs: [URL] = []
    @State private var showShare = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                ZStack {
                    Theme.placeholder
                    if let player {
                        VideoPlayer(player: player)
                    } else if let image {
                        ZoomableImageView(image: image)
                    } else if loading {
                        ProgressView()
                    } else if item.kind != .file {
                        Button(String(localized: "Decrypt Preview")) { Task { await preview() } }
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 54)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(height: 340)
                .listRowInsets(EdgeInsets())
            }
            Section(String(localized: "Details")) {
                LabeledContent(String(localized: "Name"), value: item.name)
                LabeledContent(String(localized: "Type"), value: item.kind.title)
                LabeledContent(String(localized: "Size"), value: Formatters.bytes(item.manifest.payloadBytes))
                LabeledContent(String(localized: "Date"), value: item.date.formatted(date: .long, time: .shortened))
                if let dims = Formatters.dimensions(width: item.manifest.pixelWidth, height: item.manifest.pixelHeight) {
                    LabeledContent(String(localized: "Dimensions"), value: dims)
                }
                if let duration = item.manifest.duration { LabeledContent(String(localized: "Duration"), value: Formatters.duration(duration)) }
                ForEach(item.manifest.resources.filter { $0.role != .thumbnail }, id: \.objectId) { resource in
                    LabeledContent(resource.role.rawValue, value: "\(resource.filename) · \(Formatters.bytes(resource.size))")
                }
            }
            Section {
                if item.kind != .file {
                    Button { Task { await restoreToPhotos() } } label: { Label(String(localized: "Restore to Photos"), systemImage: "photo.badge.arrow.down") }
                }
                Button { Task { await export() } } label: { Label(String(localized: "Save to Files…"), systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmDelete = true } label: { Label(String(localized: "Delete Backup from Server"), systemImage: "trash") }
            } footer: {
                if let status { Text(status).foregroundStyle(Theme.success) }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(loading)
        .sheet(isPresented: $showShare, onDismiss: cleanupExport) { ShareSheet(items: exportURLs) }
        .confirmationDialog(String(localized: "Delete this backup permanently?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await delete() } }
        } message: {
            Text(String(localized: "The encrypted copy is removed from the server. Photos on this iPhone are not affected."))
        }
        .onDisappear(perform: cleanupPreview)
    }

    private func preview() async {
        loading = true
        defer { loading = false }
        do {
            let service = try model.restoreService()
            guard let primary = item.manifest.primary else { throw RestoreError.missingResource }
            let url = try await service.decrypt(primary)
            tempFolder = url.deletingLastPathComponent()
            if item.kind == .video {
                player = AVPlayer(url: url)
            } else {
                let maxPixel = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale * 2
                image = await Task.detached { ImageDownsampler.downsample(fileURL: url, maxPixelSize: maxPixel) }.value
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                tempFolder = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restoreToPhotos() async {
        loading = true
        defer { loading = false }
        do {
            try await model.restoreService().restoreToPhotos(item)
            status = String(localized: "Restored to Photos and verified.")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() async {
        loading = true
        defer { loading = false }
        do {
            exportURLs = try await model.restoreService().decryptForExport(item)
            showShare = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            try await model.api?.deleteItem(item.id)
            library.remove(item)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cleanupExport() {
        if let folder = exportURLs.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        exportURLs = []
    }

    private func cleanupPreview() {
        player?.pause()
        player = nil
        if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) }
        tempFolder = nil
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Restores everything (or all media) to Photos with progress and verification.
struct RestoreView: View {
    let library: VaultLibraryModel
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var done = 0
    @State private var failed: [String] = []
    @State private var total = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "Downloads every photo and video from this backup directory, decrypts it on this iPhone, verifies its SHA-256 and adds it to Photos with its original resources (Live Photos included). Files can be saved individually from the Files tab."))
                        .font(.subheadline)
                }
                Section {
                    if running || done > 0 {
                        ProgressView(value: total > 0 ? Double(done + failed.count) / Double(total) : 0)
                        Text(String(localized: "\(done) restored · \(failed.count) failed · \(total) total")).font(.caption)
                    }
                    if running {
                        Button(String(localized: "Stop"), role: .destructive) { task?.cancel() }
                    } else {
                        Button(String(localized: "Restore All Photos & Videos")) { start() }.bold()
                    }
                }
                if !failed.isEmpty {
                    Section(String(localized: "Failed")) { ForEach(failed, id: \.self) { Text($0).font(.caption) } }
                }
            }
            .navigationTitle(String(localized: "Restore"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { task?.cancel(); dismiss() } } }
        }
    }

    private func start() {
        running = true
        done = 0
        failed = []
        task = Task {
            defer { running = false }
            while !library.reachedEnd && !Task.isCancelled { await library.loadMore(model) }
            let media = library.media
            total = media.count
            guard let service = try? model.restoreService() else { return }
            for item in media {
                if Task.isCancelled { break }
                do {
                    try await service.restoreToPhotos(item)
                    done += 1
                } catch {
                    failed.append("\(item.name): \(error.localizedDescription)")
                }
            }
        }
    }
}
