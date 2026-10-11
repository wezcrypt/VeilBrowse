import Foundation
import Observation

/// Album management. Removing items from an album or deleting an album never
/// deletes the media itself.
@MainActor
@Observable
final class AlbumStore {
    private(set) var albums: [Album] = []
    private(set) var smart: AlbumsResponse.Smart?
    private(set) var recentlyAddedSince: Date = Date().addingTimeInterval(-30 * 86_400)
    private(set) var isLoading = false
    var error: String?
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.albums()
            albums = response.albums
            smart = response.smart
            recentlyAddedSince = response.recentlyAddedSince
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func create(name: String, mediaIDs: [String] = []) async -> Album? {
        do {
            let album = try await api.createAlbum(name: name, mediaIDs: mediaIDs)
            albums.insert(album, at: 0)
            return album
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func rename(_ album: Album, to name: String) async {
        do {
            let updated = try await api.renameAlbum(album.id, name: name)
            replace(updated)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ album: Album) async {
        do {
            try await api.deleteAlbum(album.id)
            albums.removeAll { $0.id == album.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func add(_ mediaIDs: [String], to album: Album) async -> Bool {
        do {
            replace(try await api.addToAlbum(album.id, mediaIDs: mediaIDs))
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func remove(_ mediaIDs: [String], from album: Album) async -> Bool {
        do {
            replace(try await api.removeFromAlbum(album.id, mediaIDs: mediaIDs))
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func replace(_ album: Album) {
        if let index = albums.firstIndex(where: { $0.id == album.id }) {
            albums[index] = album
        } else {
            albums.insert(album, at: 0)
        }
    }

    func reset() {
        albums = []
        smart = nil
    }
}
