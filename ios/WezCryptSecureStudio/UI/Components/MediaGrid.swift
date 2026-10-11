import SwiftUI

/// Square thumbnail cell for a vault item.
struct RemoteThumbnailCell: View {
    let item: MediaItem
    var isSelected = false
    var isSelecting = false
    @Environment(AppEnvironment.self) private var env
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
                        .transition(.opacity)
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo, let duration = item.duration {
                    Text(Formatters.duration(duration))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.25))
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .overlay {
                if isSelected {
                    Color.white.opacity(0.18)
                }
            }
            .task(id: item.id) {
                let size = proxy.size.width * displayScale
                if let cached = env.images.cachedThumbnail(item.id) {
                    image = cached
                    return
                }
                let loaded = await env.images.thumbnail(for: item, pixelSize: max(size, 120))
                if !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var parts = [item.isVideo ? String(localized: "Video") : String(localized: "Photo")]
        parts.append(item.takenAt.formatted(date: .abbreviated, time: .shortened))
        if let duration = item.duration { parts.append(Formatters.duration(duration)) }
        if item.isFavorite { parts.append(String(localized: "Favorite")) }
        return parts.joined(separator: ", ")
    }
}

/// Lazily loaded vault grid with multi-select. Only visible cells load thumbnails.
struct VaultGridView: View {
    @Bindable var model: VaultLibraryModel
    @Binding var selection: Set<String>
    var isSelecting: Bool
    var emptyTitle: String = String(localized: "No Photos or Videos")
    var emptyMessage: String = String(localized: "Use Sync All in Transfers to upload your library.")
    var onOpen: (MediaItem) -> Void
    @Environment(AppEnvironment.self) private var env

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: env.settings.gridColumns)
    }

    var body: some View {
        ScrollView {
            if let error = model.error, model.items.isEmpty {
                ErrorBanner(message: error) { Task { await model.reload() } }
                    .padding()
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.items) { item in
                    RemoteThumbnailCell(item: item, isSelected: selection.contains(item.id), isSelecting: isSelecting)
                        .onTapGesture {
                            if isSelecting {
                                toggle(item.id)
                            } else {
                                onOpen(item)
                            }
                        }
                        .task { await model.loadMoreIfNeeded(current: item) }
                }
            }
            if model.isLoading {
                ProgressView()
                    .padding(24)
            } else if !model.items.isEmpty {
                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
        }
        .overlay {
            if model.hasLoaded, model.items.isEmpty, model.error == nil, !model.isLoading {
                ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle.angled", description: Text(emptyMessage))
            }
        }
        .refreshable { await model.reload() }
        .task { await model.loadIfNeeded() }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var footerText: String {
        let photos = model.items.filter { !$0.isVideo }.count
        let videos = model.items.count - photos
        let suffix = model.reachedEnd ? "" : "+"
        return String(localized: "\(photos)\(suffix) Photos, \(videos)\(suffix) Videos")
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

/// Toolbar actions for a multi-selection in the vault.
struct SelectionActionBar: View {
    let count: Int
    var onFavorite: () -> Void
    var onAddToAlbum: () -> Void
    var onRemoveFromAlbum: (() -> Void)?
    var onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onFavorite) { Image(systemName: "heart") }
                .accessibilityLabel(String(localized: "Favorite"))
            Spacer()
            Text(count == 0 ? String(localized: "Select Items") : String(localized: "\(count) Selected"))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                Button(action: onAddToAlbum) { Label(String(localized: "Add to Album"), systemImage: "rectangle.stack.badge.plus") }
                if let onRemoveFromAlbum {
                    Button(action: onRemoveFromAlbum) { Label(String(localized: "Remove from Album"), systemImage: "rectangle.stack.badge.minus") }
                }
                Divider()
                Button(role: .destructive, action: onDelete) { Label(String(localized: "Delete from Vault"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(String(localized: "More Actions"))
        }
        .font(.title3)
        .disabled(count == 0)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
