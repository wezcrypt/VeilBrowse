import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .photos: return String(localized: "Photos")
            case .videos: return String(localized: "Videos")
            }
        }

        var kind: MediaKind? {
            switch self {
            case .all: return nil
            case .photos: return .photo
            case .videos: return .video
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @State private var model: VaultLibraryModel
    @State private var text = ""
    @State private var scope: Scope = .all
    @State private var useDates = false
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var albumID: String?
    @State private var favoritesOnly = false
    @State private var showFilters = false
    @State private var selection: Set<String> = []
    @State private var viewerStart: VaultCollectionScreen.ViewerStart?

    init(api: APIClient) {
        _model = State(initialValue: VaultLibraryModel(api: api, query: .all))
    }

    private var query: LibraryQuery {
        var query = LibraryQuery()
        query.text = text
        query.mediaType = scope.kind
        query.albumID = albumID
        query.favorite = favoritesOnly ? true : nil
        if useDates {
            let calendar = Calendar.current
            query.from = calendar.startOfDay(for: min(fromDate, toDate))
            query.to = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: max(fromDate, toDate)))
        }
        return query
    }

    private var hasCriteria: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || scope != .all || useDates || albumID != nil || favoritesOnly
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasCriteria {
                    VaultGridView(
                        model: model,
                        selection: $selection,
                        isSelecting: false,
                        emptyTitle: String(localized: "No Results"),
                        emptyMessage: String(localized: "Try a different name, date range or album.")
                    ) { item in
                        viewerStart = .init(id: item.id)
                    }
                } else {
                    suggestions
                }
            }
            .navigationTitle(String(localized: "Search"))
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "File name"))
            .searchScopes($scope) {
                ForEach(Scope.allCases) { scope in Text(scope.title).tag(scope) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(String(localized: "Filters"))
                }
            }
            .sheet(isPresented: $showFilters) { filters }
            .task(id: query) {
                guard hasCriteria else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                model.query = query
                await model.reload()
            }
            .fullScreenCover(item: $viewerStart) { start in
                MediaViewer(model: model, startID: start.id)
            }
        }
    }

    private var activeFilterCount: Int {
        (useDates ? 1 : 0) + (albumID != nil ? 1 : 0) + (favoritesOnly ? 1 : 0)
    }

    private var suggestions: some View {
        List {
            Section(String(localized: "Quick Filters")) {
                Button { favoritesOnly = true } label: { Label(String(localized: "Favorites"), systemImage: "heart") }
                Button { scope = .videos } label: { Label(String(localized: "Videos"), systemImage: "video") }
                Button {
                    useDates = true
                    fromDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                    toDate = Date()
                } label: { Label(String(localized: "Last 7 Days"), systemImage: "calendar") }
            }
            if !env.albums.albums.isEmpty {
                Section(String(localized: "Search in Album")) {
                    ForEach(env.albums.albums.prefix(8)) { album in
                        Button { albumID = album.id } label: { Label(album.name, systemImage: "rectangle.stack") }
                    }
                }
            }
        }
        .task { if env.albums.albums.isEmpty { await env.albums.reload() } }
    }

    private var filters: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Date")) {
                    Toggle(String(localized: "Filter by Date"), isOn: $useDates)
                    if useDates {
                        DatePicker(String(localized: "From"), selection: $fromDate, displayedComponents: .date)
                        DatePicker(String(localized: "To"), selection: $toDate, displayedComponents: .date)
                    }
                }
                Section(String(localized: "Album")) {
                    Picker(String(localized: "Album"), selection: $albumID) {
                        Text(String(localized: "All Items")).tag(String?.none)
                        ForEach(env.albums.albums) { album in
                            Text(album.name).tag(Optional(album.id))
                        }
                    }
                }
                Section {
                    Toggle(String(localized: "Favorites Only"), isOn: $favoritesOnly)
                }
                Section {
                    Button(String(localized: "Reset Filters"), role: .destructive) {
                        useDates = false
                        albumID = nil
                        favoritesOnly = false
                    }
                }
            }
            .navigationTitle(String(localized: "Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { showFilters = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
