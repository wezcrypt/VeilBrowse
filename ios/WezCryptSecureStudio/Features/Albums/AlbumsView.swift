import SwiftUI

enum AlbumRoute: Hashable {
    case album(Album)
    case favorites
    case videos
    case screenshots
    case recentlyAdded
}

struct AlbumsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showCreate = false
    @State private var newName = ""
    @State private var renaming: Album?
    @State private var renameText = ""
    @State private var deleting: Album?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let store = env.albums
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let error = store.error {
                        ErrorBanner(message: error) { Task { await store.reload() } }
                    }
                    sectionHeader(String(localized: "My Albums"), count: store.albums.count)
                    if store.albums.isEmpty && !store.isLoading {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "No albums yet")).font(.headline)
                                Text(String(localized: "Create an album, then select items in the Library and choose Add to Album."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Button(String(localized: "New Album")) { showCreate = true }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.top, 4)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(store.albums) { album in
                                NavigationLink(value: AlbumRoute.album(album)) {
                                    AlbumCard(title: album.name, subtitle: String(localized: "\(album.itemCount) · \(Formatters.bytes(album.totalBytes))"), coverID: album.coverMediaId)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { renameText = album.name; renaming = album } label: { Label(String(localized: "Rename"), systemImage: "pencil") }
                                    Button(role: .destructive) { deleting = album } label: { Label(String(localized: "Delete Album"), systemImage: "trash") }
                                }
                            }
                        }
                    }

                    sectionHeader(String(localized: "Media Types"), count: nil)
                    VStack(spacing: 0) {
                        smartRow(.favorites, title: String(localized: "Favorites"), symbol: "heart", stats: store.smart?.favorites)
                        Divider().padding(.leading, 56)
                        smartRow(.videos, title: String(localized: "Videos"), symbol: "video", stats: store.smart?.videos)
                        Divider().padding(.leading, 56)
                        smartRow(.screenshots, title: String(localized: "Screenshots"), symbol: "camera.viewfinder", stats: store.smart?.screenshots)
                        Divider().padding(.leading, 56)
                        smartRow(.recentlyAdded, title: String(localized: "Recently Added"), symbol: "clock.arrow.circlepath", stats: store.smart?.recentlyAdded)
                    }
                    .cardBackground()
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "Albums"))
            .navigationDestination(for: AlbumRoute.self) { route in
                destination(route)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(String(localized: "New Album"))
                }
            }
            .refreshable { await store.reload() }
            .task { await store.reload() }
            .alert(String(localized: "New Album"), isPresented: $showCreate) {
                TextField(String(localized: "Name"), text: $newName)
                Button(String(localized: "Create")) {
                    let name = newName
                    newName = ""
                    Task { await store.create(name: name) }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(String(localized: "Cancel"), role: .cancel) { newName = "" }
            }
            .alert(String(localized: "Rename Album"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(String(localized: "Name"), text: $renameText)
                Button(String(localized: "Save")) {
                    if let album = renaming {
                        let name = renameText
                        Task { await store.rename(album, to: name) }
                    }
                    renaming = nil
                }
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(String(localized: "Cancel"), role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                String(localized: "Delete this album?"),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete Album"), role: .destructive) {
                    if let album = deleting { Task { await store.delete(album) } }
                    deleting = nil
                }
            } message: {
                Text(String(localized: "Photos and videos in the album stay in your vault."))
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            if let count, count > 0 {
                Text("\(count)").foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func smartRow(_ route: AlbumRoute, title: String, symbol: String, stats: SmartAlbumStats?) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let stats {
                    Text("\(stats.itemCount)").foregroundStyle(.secondary).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(stats.map { String(localized: "\($0.itemCount) items, \(Formatters.bytes($0.totalBytes))") } ?? "")
    }

    @ViewBuilder
    private func destination(_ route: AlbumRoute) -> some View {
        switch route {
        case .album(let album):
            VaultCollectionScreen(
                title: album.name,
                query: LibraryQuery(albumID: album.id),
                api: env.api,
                album: album,
                emptyTitle: String(localized: "Empty Album"),
                emptyMessage: String(localized: "Select items in the Library and choose Add to Album.")
            )
        case .favorites:
            VaultCollectionScreen(title: String(localized: "Favorites"), query: LibraryQuery(favorite: true), api: env.api, emptyTitle: String(localized: "No Favorites"), emptyMessage: String(localized: "Tap the heart on any item to add it here."))
        case .videos:
            VaultCollectionScreen(title: String(localized: "Videos"), query: LibraryQuery(mediaType: .video), api: env.api, emptyTitle: String(localized: "No Videos"))
        case .screenshots:
            VaultCollectionScreen(title: String(localized: "Screenshots"), query: LibraryQuery(screenshot: true), api: env.api, emptyTitle: String(localized: "No Screenshots"))
        case .recentlyAdded:
            VaultCollectionScreen(title: String(localized: "Recently Added"), query: LibraryQuery(addedSince: env.albums.recentlyAddedSince, sort: .added), api: env.api, emptyTitle: String(localized: "Nothing Added Recently"))
        }
    }
}

struct AlbumCard: View {
    let title: String
    let subtitle: String
    let coverID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverThumbnail(mediaID: coverID)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
