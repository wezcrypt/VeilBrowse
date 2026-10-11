import Foundation
import Observation

/// Cursor-paginated view of the vault for one query. Pages are fetched on demand
/// as the grid scrolls, so libraries with 100k+ items never load all metadata.
@MainActor
@Observable
final class VaultLibraryModel {
    private(set) var items: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    var query: LibraryQuery

    private let api: APIClient
    private let pageSize: Int
    private var cursor: String?
    private var indexByID: [String: Int] = [:]
    private var generation = 0

    init(api: APIClient, query: LibraryQuery, pageSize: Int = 240) {
        self.api = api
        self.query = query
        self.pageSize = pageSize
    }

    func reload() async {
        generation += 1
        cursor = nil
        reachedEnd = false
        error = nil
        isLoading = false
        await loadPage(replacing: true)
    }

    func loadIfNeeded() async {
        if !hasLoaded { await reload() }
    }

    func loadMoreIfNeeded(current item: MediaItem) async {
        guard !reachedEnd, !isLoading, let index = indexByID[item.id], index >= items.count - 60 else { return }
        await loadPage(replacing: false)
    }

    private func loadPage(replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        let requestGeneration = generation
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let page = try await api.library(query, cursor: replacing ? nil : cursor, limit: pageSize)
            guard requestGeneration == generation else { return }
            if replacing {
                items = page.items
            } else {
                let fresh = page.items.filter { indexByID[$0.id] == nil }
                items.append(contentsOf: fresh)
            }
            rebuildIndex()
            cursor = page.nextCursor
            reachedEnd = page.nextCursor == nil
            hasLoaded = true
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() { indexByID[item.id] = index }
    }

    func replace(_ item: MediaItem) {
        guard let index = indexByID[item.id] else { return }
        items[index] = item
    }

    func remove(ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        rebuildIndex()
    }

    func item(id: String) -> MediaItem? {
        indexByID[id].map { items[$0] }
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Day / month / year buckets for the Library tab.
@MainActor
@Observable
final class SummaryModel {
    private(set) var buckets: [SummaryBucket] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var reachedEnd = false
    let granularity: SummaryGranularity
    private let api: APIClient
    private var nextBefore: String?

    init(api: APIClient, granularity: SummaryGranularity) {
        self.api = api
        self.granularity = granularity
    }

    func reload() async {
        nextBefore = nil
        reachedEnd = false
        await load(replacing: true)
    }

    func loadMoreIfNeeded(current bucket: SummaryBucket) async {
        guard !reachedEnd, !isLoading, bucket.id == buckets.last?.id else { return }
        await load(replacing: false)
    }

    private func load(replacing: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.summary(granularity, before: replacing ? nil : nextBefore)
            buckets = replacing ? page.buckets : buckets + page.buckets
            nextBefore = page.nextBefore
            reachedEnd = page.nextBefore == nil
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
