import Foundation

/// Library query sent to `GET /api/mobile/library`.
struct LibraryQuery: Equatable, Hashable, Sendable {
    enum Sort: String, Sendable { case taken, added }

    var mediaType: MediaKind?
    var favorite: Bool?
    var screenshot: Bool?
    var text: String?
    var from: Date?
    var to: Date?
    var albumID: String?
    var addedSince: Date?
    var sort: Sort = .taken

    static let all = LibraryQuery()

    func queryItems(cursor: String?, limit: Int) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "sort", value: sort.rawValue)]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let mediaType { items.append(URLQueryItem(name: "type", value: mediaType.rawValue)) }
        if let favorite { items.append(URLQueryItem(name: "favorite", value: favorite ? "true" : "false")) }
        if let screenshot { items.append(URLQueryItem(name: "screenshot", value: screenshot ? "true" : "false")) }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            items.append(URLQueryItem(name: "q", value: String(text.prefix(200))))
        }
        if let from { items.append(URLQueryItem(name: "from", value: String(Int(from.timeIntervalSince1970)))) }
        if let to { items.append(URLQueryItem(name: "to", value: String(Int(to.timeIntervalSince1970)))) }
        if let albumID { items.append(URLQueryItem(name: "album_id", value: albumID)) }
        if let addedSince { items.append(URLQueryItem(name: "added_since", value: String(Int(addedSince.timeIntervalSince1970)))) }
        return items
    }
}

enum SummaryGranularity: String, Sendable, CaseIterable {
    case day, month, year
}

extension APIClient {
    // MARK: Pairing & session

    func startPairing(_ body: PairStartRequest) async throws -> PairStartResponse {
        try await decode(try .json("POST", "/api/mobile/pair/start", body, requiresAuth: false))
    }

    func pollPairing(_ body: PairPollRequest) async throws -> PairPollResponse {
        try await decode(try .json("POST", "/api/mobile/pair/poll", body, requiresAuth: false))
    }

    func logout() async throws {
        _ = try await send(Endpoint(method: "POST", path: "/api/mobile/session/logout"))
    }

    func devices() async throws -> [DeviceInfo] {
        try await decode(.get("/api/mobile/devices"), as: DevicesResponse.self).devices
    }

    func revokeDevice(_ id: String) async throws {
        _ = try await send(Endpoint(method: "DELETE", path: "/api/mobile/devices/\(id)"))
    }

    func account() async throws -> AccountInfo {
        try await decode(.get("/api/mobile/account"))
    }

    // MARK: Library

    func library(_ query: LibraryQuery, cursor: String?, limit: Int = 200) async throws -> LibraryPage {
        try await decode(.get("/api/mobile/library", query: query.queryItems(cursor: cursor, limit: limit)))
    }

    func summary(_ granularity: SummaryGranularity, before: String?, limit: Int = 500) async throws -> SummaryPage {
        let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
        var items = [
            URLQueryItem(name: "granularity", value: granularity.rawValue),
            URLQueryItem(name: "tz_offset_minutes", value: String(offsetMinutes)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        return try await decode(.get("/api/mobile/library/summary", query: items))
    }

    func media(_ id: String) async throws -> MediaItem {
        try await decode(.get("/api/mobile/media/\(id)"))
    }

    func updateMedia(_ id: String, filename: String? = nil, isFavorite: Bool? = nil) async throws -> MediaItem {
        try await decode(try .json("PATCH", "/api/mobile/media/\(id)", MediaPatchBody(filename: filename, isFavorite: isFavorite)))
    }

    func setFavorite(_ ids: [String], favorite: Bool) async throws {
        _ = try await send(try .json("POST", "/api/mobile/media/favorite", BulkFavoriteBody(mediaIds: ids, isFavorite: favorite)))
    }

    /// Permanently deletes media from the vault. Never touches the iPhone's Photos library.
    func deleteMedia(_ ids: [String]) async throws -> Int {
        var endpoint = try Endpoint.json("POST", "/api/mobile/media/delete", MediaIDsBody(mediaIds: ids))
        endpoint.headers["X-WZC-Confirm-Delete"] = "yes"
        return try await decode(endpoint, as: CountResponse.self).deleted ?? 0
    }

    func thumbnailData(_ id: String) async throws -> Data {
        var endpoint = Endpoint.get("/api/mobile/media/\(id)/thumbnail")
        endpoint.timeout = 30
        return try await send(endpoint).0
    }

    func uploadThumbnail(_ id: String, jpeg: Data) async throws {
        _ = try await send(Endpoint(method: "PUT", path: "/api/mobile/media/\(id)/thumbnail", body: jpeg, contentType: "image/jpeg"))
    }

    func downloadContent(_ id: String) async throws -> URL {
        var endpoint = Endpoint.get("/api/mobile/media/\(id)/content")
        endpoint.timeout = 300
        return try await download(endpoint)
    }

    struct RangeResult: Sendable {
        let data: Data
        let totalLength: Int64
        let mimeType: String
    }

    /// Fetches an inclusive byte range of decrypted content (HTTP Range).
    func contentRange(_ id: String, range: ClosedRange<Int64>) async throws -> RangeResult {
        var endpoint = Endpoint.get("/api/mobile/media/\(id)/content")
        endpoint.headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        endpoint.timeout = 120
        let (data, response) = try await send(endpoint)
        let mime = response.mimeType ?? "application/octet-stream"
        if response.statusCode == 206, let header = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = header.lastIndex(of: "/"), let total = Int64(header[header.index(after: slash)...]) {
            return RangeResult(data: data, totalLength: total, mimeType: mime)
        }
        // Server ignored the range (200): slice locally.
        let total = Int64(data.count)
        let lower = Int(min(range.lowerBound, total))
        let upper = Int(min(range.upperBound + 1, total))
        return RangeResult(data: data.subdata(in: lower..<upper), totalLength: total, mimeType: mime)
    }

    // MARK: Albums

    func albums() async throws -> AlbumsResponse {
        try await decode(.get("/api/mobile/albums"))
    }

    func createAlbum(name: String, mediaIDs: [String] = []) async throws -> Album {
        try await decode(try .json("POST", "/api/mobile/albums", AlbumCreateBody(name: name, mediaIds: mediaIDs)))
    }

    func renameAlbum(_ id: String, name: String) async throws -> Album {
        try await decode(try .json("PATCH", "/api/mobile/albums/\(id)", NameBody(name: name)))
    }

    func deleteAlbum(_ id: String) async throws {
        _ = try await send(Endpoint(method: "DELETE", path: "/api/mobile/albums/\(id)"))
    }

    func addToAlbum(_ id: String, mediaIDs: [String]) async throws -> Album {
        try await decode(try .json("POST", "/api/mobile/albums/\(id)/items", MediaIDsBody(mediaIds: mediaIDs)))
    }

    func removeFromAlbum(_ id: String, mediaIDs: [String]) async throws -> Album {
        try await decode(try .json("POST", "/api/mobile/albums/\(id)/items/remove", MediaIDsBody(mediaIds: mediaIDs)))
    }

    // MARK: Uploads

    func createUpload(_ body: CreateUploadRequest) async throws -> CreateUploadResponse {
        try await decode(try .json("POST", "/api/mobile/uploads", body))
    }

    func uploadStatus(_ id: String) async throws -> UploadProgressResponse {
        try await decode(.get("/api/mobile/uploads/\(id)"))
    }

    func completeUpload(_ id: String) async throws -> CompleteUploadResponse {
        var endpoint = Endpoint(method: "POST", path: "/api/mobile/uploads/\(id)/complete")
        endpoint.timeout = 600
        return try await decode(endpoint)
    }

    func cancelUpload(_ id: String) async throws {
        _ = try await send(Endpoint(method: "DELETE", path: "/api/mobile/uploads/\(id)"))
    }

    func checkHashes(_ hashes: [String]) async throws -> [String: String] {
        struct Body: Encodable, Sendable { let sha256: [String] }
        return try await decode(try .json("POST", "/api/mobile/sync/check", Body(sha256: hashes)), as: SyncCheckResponse.self).existing
    }
}
