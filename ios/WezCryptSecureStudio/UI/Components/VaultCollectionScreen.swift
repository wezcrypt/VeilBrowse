import SwiftUI

/// A vault grid with selection, favorites, album management, deletion and the
/// full-screen viewer. Reused by Library, Albums and Search.
struct VaultCollectionScreen: View {
    let title: String
    var album: Album?
    var emptyTitle: String = String(localized: "No Photos or Videos")
    var emptyMessage: String = String(localized: "Use Sync All in Transfers to upload your library.")
    var setsNavigationTitle = true

    @State private var model: VaultLibraryModel
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var viewerStart: ViewerStart?
    @State private var showAlbumPicker = false
    @State private var confirmDelete = false
    @State private var actionError: String?
    @Environment(AppEnvironment.self) private var env

    struct ViewerStart: Identifiable { let id: String }

    init(title: String, query: LibraryQuery, api: APIClient, album: Album? = nil, emptyTitle: String? = nil, emptyMessage: String? = nil, setsNavigationTitle: Bool = true) {
        self.title = title
        self.album = album
        if let emptyTitle { self.emptyTitle = emptyTitle }
        if let emptyMessage { self.emptyMessage = emptyMessage }
        self.setsNavigationTitle = setsNavigationTitle
        _model = State(initialValue: VaultLibraryModel(api: api, query: query))
    }

    var body: some View {
        VaultGridView(
            model: model,
            selection: $selection,
            isSelecting: isSelecting,
            emptyTitle: emptyTitle,
            emptyMessage: emptyMessage
        ) { item in
            viewerStart = ViewerStart(id: item.id)
        }
        .navigationTitle(setsNavigationTitle ? title : "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? String(localized: "Cancel") : String(localized: "Select")) {
                    withAnimation(.snappy) {
                        isSelecting.toggle()
                        selection.removeAll()
                    }
                }
                .disabled(model.items.isEmpty && !isSelecting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(String(localized: "Grid Size"), selection: Bindable(env.settings).gridColumns) {
                        Text(String(localized: "Large")).tag(3)
                        Text(String(localized: "Medium")).tag(4)
                        Text(String(localized: "Small")).tag(5)
                        Text(String(localized: "Compact")).tag(6)
                    }
                } label: {
                    Image(systemName: "square.grid.3x3")
                }
                .accessibilityLabel(String(localized: "Grid Size"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                SelectionActionBar(
                    count: selection.count,
                    onFavorite: { Task { await toggleFavorite() } },
                    onAddToAlbum: { showAlbumPicker = true },
                    onRemoveFromAlbum: album == nil ? nil : { Task { await removeFromAlbum() } },
                    onDelete: { confirmDelete = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            String(localized: "Delete \(selection.count) items from the vault?"),
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Permanently"), role: .destructive) { Task { await deleteSelection() } }
        } message: {
            Text(String(localized: "The encrypted copies on the server are removed. Photos on this iPhone are not affected."))
        }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerSheet(mediaIDs: Array(selection)) {
                withAnimation { isSelecting = false; selection.removeAll() }
            }
        }
        .fullScreenCover(item: $viewerStart) { start in
            MediaViewer(model: model, startID: start.id, album: album)
        }
        .alert(String(localized: "Something went wrong"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var selectedItems: [MediaItem] {
        selection.compactMap { model.item(id: $0) }
    }

    private func toggleFavorite() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let makeFavorite = !items.allSatisfy(\.isFavorite)
        do {
            try await env.api.setFavorite(items.map(\.id), favorite: makeFavorite)
            for var item in items {
                item.isFavorite = makeFavorite
                model.replace(item)
            }
            if model.query.favorite == true && !makeFavorite {
                model.remove(ids: Set(items.map(\.id)))
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removeFromAlbum() async {
        guard let album else { return }
        let ids = Array(selection)
        if await env.albums.remove(ids, from: album) {
            model.remove(ids: Set(ids))
            selection.removeAll()
            isSelecting = false
        } else {
            actionError = env.albums.error
        }
    }

    private func deleteSelection() async {
        let ids = Array(selection)
        do {
            _ = try await env.api.deleteMedia(ids)
            model.remove(ids: Set(ids))
            await env.images.evict(ids)
            selection.removeAll()
            isSelecting = false
            await env.albums.reload()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Adds items to an existing album or a new one.
struct AlbumPickerSheet: View {
    let mediaIDs: [String]
    var onDone: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumName = ""
    @State private var showNewAlbum = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNewAlbum = true
                    } label: {
                        Label(String(localized: "New Album…"), systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                Section(String(localized: "My Albums")) {
                    if env.albums.albums.isEmpty {
                        Text(String(localized: "No albums yet"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(env.albums.albums) { album in
                        Button {
                            Task {
                                working = true
                                if await env.albums.add(mediaIDs, to: album) {
                                    onDone()
                                    dismiss()
                                }
                                working = false
                            }
                        } label: {
                            HStack(spacing: 12) {
                                CoverThumbnail(mediaID: album.coverMediaId)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading) {
                                    Text(album.name).foregroundStyle(.primary)
                                    Text(String(localized: "\(album.itemCount) items")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .navigationTitle(String(localized: "Add to Album"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .alert(String(localized: "New Album"), isPresented: $showNewAlbum) {
                TextField(String(localized: "Name"), text: $newAlbumName)
                Button(String(localized: "Create")) {
                    let name = newAlbumName
                    newAlbumName = ""
                    Task {
                        working = true
                        if await env.albums.create(name: name, mediaIDs: mediaIDs) != nil {
                            onDone()
                            dismiss()
                        }
                        working = false
                    }
                }
                .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(String(localized: "Cancel"), role: .cancel) { newAlbumName = "" }
            }
            .task { if env.albums.albums.isEmpty { await env.albums.reload() } }
        }
        .presentationDetents([.medium, .large])
    }
}
