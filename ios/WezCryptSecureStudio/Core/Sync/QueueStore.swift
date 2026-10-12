import Foundation
import SQLite3

enum AssetSource: String, Sendable { case photos, files }

enum AssetState: String, Sendable, CaseIterable {
    case pending, preparing, uploading, finalizing, completed, duplicate, failed

    var title: String {
        switch self {
        case .pending: return String(localized: "Waiting")
        case .preparing: return String(localized: "Encrypting")
        case .uploading: return String(localized: "Uploading")
        case .finalizing: return String(localized: "Verifying")
        case .completed: return String(localized: "Backed up")
        case .duplicate: return String(localized: "Already backed up")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct ScannedAsset: Sendable, Hashable {
    let localID: String
    let kind: ItemKind
    let createdAt: Date?
}

struct QueueAsset: Sendable, Identifiable, Hashable {
    let localID: String
    let source: AssetSource
    let kind: ItemKind
    let createdAt: Date?
    var state: AssetState
    var itemID: String?
    var displayName: String?
    var totalBytes: Int64?
    var attempts: Int
    var lastError: String?
    var stagedName: String?
    var updatedAt: Date

    var id: String { localID }
}

struct QueueObject: Sendable, Equatable {
    let objectID: String
    let localID: String
    let role: ResourceRole
    let filename: String
    let uti: String?
    let plainSize: Int64
    let plainSHA256: String
    let cipherSize: Int64
    let cipherSHA256: String
    let chunkSize: Int
    let chunkCount: Int
    var uploadID: String?
    var completed: Bool
}

struct QueueChunk: Sendable, Hashable {
    let objectID: String
    let index: Int
    let fileName: String
    let size: Int
    let sha256: String
    var uploadID: String?
    var attempts: Int

    var key: String { "\(objectID)#\(index)" }
}

struct QueueCounts: Sendable, Equatable {
    var pending = 0
    var active = 0
    var completed = 0
    var failed = 0
    var total: Int { pending + active + completed + failed }
    var remaining: Int { pending + active }
}

struct PreparedItem: Sendable {
    let localID: String
    let itemID: String
    let kind: ItemKind
    let manifest: Data
    let contentTag: String
    let objectIDs: [String]
}

enum QueueError: Error, LocalizedError {
    case sqlite(String)
    var errorDescription: String? { if case .sqlite(let message) = self { return "Queue database error: \(message)" }; return nil }
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}

/// Durable upload queue. Survives app termination: every state transition is
/// committed before the corresponding network step, and chunk files are
/// referenced by name (the app container path can change across updates).
actor QueueStore {
    private enum Value { case text(String), int(Int64), double(Double), blob(Data), null }

    private let handle: SQLiteHandle
    private var db: OpaquePointer { handle.pointer }

    init(path: String) throws {
        var pointer: OpaquePointer?
        var flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if path != ":memory:" { flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION }
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(pointer)
            throw QueueError.sqlite(message)
        }
        handle = SQLiteHandle(pointer)
        try Self.migrate(pointer)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw QueueError.sqlite(message)
        }
    }

    private static func migrate(_ db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        var version: Int32 = 0
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        guard version < 1 else { return }
        try exec(db, """
        BEGIN;
        CREATE TABLE assets (
            local_id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            created_at REAL,
            state TEXT NOT NULL,
            item_id TEXT,
            display_name TEXT,
            total_bytes INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            retry_after REAL NOT NULL DEFAULT 0,
            staged_name TEXT,
            manifest BLOB,
            content_tag TEXT,
            seen_generation INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE INDEX ix_assets_state ON assets(state, retry_after, created_at DESC);
        CREATE INDEX ix_assets_tag ON assets(content_tag);
        CREATE TABLE objects (
            object_id TEXT PRIMARY KEY,
            local_id TEXT NOT NULL REFERENCES assets(local_id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            filename TEXT NOT NULL,
            uti TEXT,
            plain_size INTEGER NOT NULL,
            plain_sha256 TEXT NOT NULL,
            cipher_size INTEGER NOT NULL,
            cipher_sha256 TEXT NOT NULL,
            chunk_size INTEGER NOT NULL,
            chunk_count INTEGER NOT NULL,
            upload_id TEXT,
            completed INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX ix_objects_asset ON objects(local_id);
        CREATE TABLE chunks (
            object_id TEXT NOT NULL REFERENCES objects(object_id) ON DELETE CASCADE,
            idx INTEGER NOT NULL,
            file_name TEXT NOT NULL,
            size INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            done INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            retry_after REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (object_id, idx)
        );
        CREATE INDEX ix_chunks_pending ON chunks(done, retry_after);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB);
        PRAGMA user_version = 1;
        COMMIT;
        """)
    }

    // MARK: - SQL helpers

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw QueueError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw QueueError.sqlite(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    private func rows<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { output.append(map(statement)) } else if result == SQLITE_DONE { break } else {
                throw QueueError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        return output
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try run("COMMIT")
            return value
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private static func text(_ s: OpaquePointer, _ c: Int32) -> String? {
        guard sqlite3_column_type(s, c) != SQLITE_NULL, let p = sqlite3_column_text(s, c) else { return nil }
        return String(cString: p)
    }

    private static func int(_ s: OpaquePointer, _ c: Int32) -> Int64? {
        sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c)
    }

    private static func blob(_ s: OpaquePointer, _ c: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(s, c) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, c)))
    }

    private var now: Double { Date().timeIntervalSince1970 }

    private static let assetColumns = "local_id, source, kind, created_at, state, item_id, display_name, total_bytes, attempts, last_error, staged_name, updated_at"

    private static func asset(_ s: OpaquePointer) -> QueueAsset {
        QueueAsset(
            localID: text(s, 0) ?? "",
            source: AssetSource(rawValue: text(s, 1) ?? "") ?? .photos,
            kind: ItemKind(rawValue: text(s, 2) ?? "") ?? .photo,
            createdAt: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
            state: AssetState(rawValue: text(s, 4) ?? "") ?? .pending,
            itemID: text(s, 5),
            displayName: text(s, 6),
            totalBytes: int(s, 7),
            attempts: Int(sqlite3_column_int(s, 8)),
            lastError: text(s, 9),
            stagedName: text(s, 10),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 11))
        )
    }

    // MARK: - Discovery

    func nextGeneration() throws -> Int64 {
        let next = (try metaInt("scan.generation") ?? 0) + 1
        try setMetaInt("scan.generation", next)
        return next
    }

    @discardableResult
    func upsertScanned(_ assets: [ScannedAsset], generation: Int64) throws -> Int {
        let timestamp = now
        return try transaction {
            var inserted = 0
            for asset in assets {
                let updated = try run("UPDATE assets SET seen_generation = ? WHERE local_id = ?", [.int(generation), .text(asset.localID)])
                if updated == 0 {
                    try run(
                        "INSERT INTO assets(local_id, source, kind, created_at, state, seen_generation, updated_at) VALUES (?, 'photos', ?, ?, 'pending', ?, ?)",
                        [.text(asset.localID), .text(asset.kind.rawValue), asset.createdAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                         .int(generation), .double(timestamp)]
                    )
                    inserted += 1
                }
            }
            return inserted
        }
    }

    func addFile(localID: String, displayName: String, stagedName: String, size: Int64, createdAt: Date?) throws {
        try run(
            """
            INSERT OR IGNORE INTO assets(local_id, source, kind, created_at, state, display_name, total_bytes, staged_name, updated_at)
            VALUES (?, 'files', 'file', ?, 'pending', ?, ?, ?, ?)
            """,
            [.text(localID), createdAt.map { .double($0.timeIntervalSince1970) } ?? .null, .text(displayName), .int(size), .text(stagedName), .double(now)]
        )
    }

    /// Drops queued (never uploaded) photo assets that disappeared from the library.
    func pruneUnseen(generation: Int64) throws {
        try run("DELETE FROM assets WHERE source = 'photos' AND seen_generation != ? AND state IN ('pending', 'failed')", [.int(generation)])
    }

    func removeDeleted(_ localIDs: [String]) throws {
        try transaction {
            for id in localIDs {
                try run("DELETE FROM assets WHERE local_id = ? AND state IN ('pending', 'failed')", [.text(id)])
            }
        }
    }

    // MARK: - Preparation

    func nextPendingAsset(kinds: Set<ItemKind>) throws -> QueueAsset? {
        let allowed = kinds.map(\.rawValue)
        guard !allowed.isEmpty else { return nil }
        let placeholders = allowed.map { _ in "?" }.joined(separator: ",")
        return try rows(
            "SELECT \(Self.assetColumns) FROM assets WHERE state = 'pending' AND retry_after <= ? AND kind IN (\(placeholders)) ORDER BY created_at DESC LIMIT 1",
            [.double(now)] + allowed.map { .text($0) },
            map: Self.asset
        ).first
    }

    func earliestRetry() throws -> Date? {
        try rows("SELECT MIN(retry_after) FROM assets WHERE state = 'pending' AND retry_after > ?", [.double(now)]) { s -> Date? in
            sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 0))
        }.first ?? nil
    }

    func markPreparing(_ localID: String) throws {
        try run("UPDATE assets SET state = 'preparing', updated_at = ? WHERE local_id = ?", [.double(now), .text(localID)])
    }

    func savePrepared(_ item: PreparedItem, displayName: String?, totalBytes: Int64, objects: [(QueueObject, [PreparedChunk])]) throws {
        try transaction {
            for (object, chunks) in objects {
                try run(
                    """
                    INSERT INTO objects(object_id, local_id, role, filename, uti, plain_size, plain_sha256, cipher_size, cipher_sha256,
                        chunk_size, chunk_count, upload_id, completed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [.text(object.objectID), .text(object.localID), .text(object.role.rawValue), .text(object.filename),
                     object.uti.map { .text($0) } ?? .null, .int(object.plainSize), .text(object.plainSHA256), .int(object.cipherSize),
                     .text(object.cipherSHA256), .int(Int64(object.chunkSize)), .int(Int64(object.chunkCount)),
                     object.uploadID.map { .text($0) } ?? .null, .int(object.completed ? 1 : 0)]
                )
                for chunk in chunks {
                    try run("INSERT INTO chunks(object_id, idx, file_name, size, sha256) VALUES (?,?,?,?,?)",
                            [.text(object.objectID), .int(Int64(chunk.index)), .text(chunk.url.lastPathComponent), .int(Int64(chunk.size)), .text(chunk.sha256)])
                }
            }
            try run(
                """
                UPDATE assets SET state = 'uploading', kind = ?, item_id = ?, manifest = ?, content_tag = ?, display_name = COALESCE(?, display_name),
                    total_bytes = ?, last_error = NULL, updated_at = ? WHERE local_id = ?
                """,
                [.text(item.kind.rawValue), .text(item.itemID), .blob(item.manifest), .text(item.contentTag),
                 displayName.map { .text($0) } ?? .null, .int(totalBytes), .double(now), .text(item.localID)]
            )
        }
    }

    func setUploadID(objectID: String, uploadID: String) throws {
        try run("UPDATE objects SET upload_id = ? WHERE object_id = ?", [.text(uploadID), .text(objectID)])
    }

    func isTagCompleted(_ tag: String, excluding localID: String) throws -> Bool {
        try !rows("SELECT 1 FROM assets WHERE content_tag = ? AND local_id != ? AND state IN ('completed', 'duplicate', 'uploading', 'finalizing') LIMIT 1",
                  [.text(tag), .text(localID)]) { _ in true }.isEmpty
    }

    // MARK: - Uploading

    func pendingChunks(limit: Int, excluding: Set<String>) throws -> [QueueChunk] {
        let candidates = try rows(
            """
            SELECT c.object_id, c.idx, c.file_name, c.size, c.sha256, o.upload_id, c.attempts
            FROM chunks c JOIN objects o ON o.object_id = c.object_id JOIN assets a ON a.local_id = o.local_id
            WHERE c.done = 0 AND c.retry_after <= ? AND o.completed = 0 AND a.state = 'uploading'
            ORDER BY (o.upload_id IS NULL), a.updated_at, c.object_id, c.idx LIMIT ?
            """,
            [.double(now), .int(Int64(limit + excluding.count))]
        ) { s in
            QueueChunk(objectID: Self.text(s, 0) ?? "", index: Int(sqlite3_column_int(s, 1)), fileName: Self.text(s, 2) ?? "",
                       size: Int(sqlite3_column_int64(s, 3)), sha256: Self.text(s, 4) ?? "", uploadID: Self.text(s, 5), attempts: Int(sqlite3_column_int(s, 6)))
        }
        return Array(candidates.filter { !excluding.contains($0.key) }.prefix(limit))
    }

    /// Server back-pressure: postpone a chunk without counting it as a failed attempt.
    func deferChunk(objectID: String, index: Int, until: Date) throws {
        try run("UPDATE chunks SET retry_after = ? WHERE object_id = ? AND idx = ?",
                [.double(until.timeIntervalSince1970), .text(objectID), .int(Int64(index))])
    }

    func isChunkDone(objectID: String, index: Int) throws -> Bool {
        try rows("SELECT done FROM chunks WHERE object_id = ? AND idx = ?", [.text(objectID), .int(Int64(index))]) { sqlite3_column_int($0, 0) == 1 }.first ?? true
    }

    /// Server upload sessions opened for an asset's unfinished objects (cancelled on the
    /// server when the asset is re-prepared or fails, so they never pile up there).
    func openUploadIDs(localID: String) throws -> [String] {
        try rows("SELECT upload_id FROM objects WHERE local_id = ? AND completed = 0 AND upload_id IS NOT NULL", [.text(localID)]) { Self.text($0, 0) ?? "" }
    }

    func openSessionCount() throws -> Int {
        try rows("SELECT COUNT(*) FROM objects WHERE completed = 0 AND upload_id IS NOT NULL") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func earliestChunkRetry() throws -> Date? {
        try rows("SELECT MIN(retry_after) FROM chunks WHERE done = 0 AND retry_after > ?", [.double(now)]) { s -> Date? in
            sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 0))
        }.first ?? nil
    }

    func markChunkDone(objectID: String, index: Int) throws {
        try run("UPDATE chunks SET done = 1 WHERE object_id = ? AND idx = ?", [.text(objectID), .int(Int64(index))])
    }

    func markChunkRetry(objectID: String, index: Int, retryAfter: Date) throws -> Int {
        try run("UPDATE chunks SET attempts = attempts + 1, retry_after = ? WHERE object_id = ? AND idx = ?",
                [.double(retryAfter.timeIntervalSince1970), .text(objectID), .int(Int64(index))])
        return try rows("SELECT attempts FROM chunks WHERE object_id = ? AND idx = ?", [.text(objectID), .int(Int64(index))]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func reopenChunks(objectID: String, indices: [Int]) throws {
        try transaction {
            for index in indices {
                try run("UPDATE chunks SET done = 0, retry_after = 0 WHERE object_id = ? AND idx = ?", [.text(objectID), .int(Int64(index))])
            }
        }
    }

    func remainingChunks(objectID: String) throws -> Int {
        try rows("SELECT COUNT(*) FROM chunks WHERE object_id = ? AND done = 0", [.text(objectID)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func object(_ objectID: String) throws -> QueueObject? {
        try rows(
            """
            SELECT object_id, local_id, role, filename, uti, plain_size, plain_sha256, cipher_size, cipher_sha256, chunk_size, chunk_count, upload_id, completed
            FROM objects WHERE object_id = ?
            """, [.text(objectID)]
        ) { s in
            QueueObject(objectID: Self.text(s, 0) ?? "", localID: Self.text(s, 1) ?? "", role: ResourceRole(rawValue: Self.text(s, 2) ?? "") ?? .file,
                        filename: Self.text(s, 3) ?? "", uti: Self.text(s, 4), plainSize: sqlite3_column_int64(s, 5), plainSHA256: Self.text(s, 6) ?? "",
                        cipherSize: sqlite3_column_int64(s, 7), cipherSHA256: Self.text(s, 8) ?? "", chunkSize: Int(sqlite3_column_int64(s, 9)),
                        chunkCount: Int(sqlite3_column_int64(s, 10)), uploadID: Self.text(s, 11), completed: sqlite3_column_int(s, 12) == 1)
        }.first
    }

    func markObjectCompleted(_ objectID: String) throws -> [String] {
        try transaction {
            let names = try rows("SELECT file_name FROM chunks WHERE object_id = ?", [.text(objectID)]) { Self.text($0, 0) ?? "" }
            try run("UPDATE objects SET completed = 1 WHERE object_id = ?", [.text(objectID)])
            try run("DELETE FROM chunks WHERE object_id = ?", [.text(objectID)])
            return names
        }
    }

    func remainingObjects(localID: String) throws -> Int {
        try rows("SELECT COUNT(*) FROM objects WHERE local_id = ? AND completed = 0", [.text(localID)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    func preparedItem(localID: String) throws -> PreparedItem? {
        let objectIDs = try rows("SELECT object_id FROM objects WHERE local_id = ? ORDER BY object_id", [.text(localID)]) { Self.text($0, 0) ?? "" }
        return try rows("SELECT item_id, kind, manifest, content_tag FROM assets WHERE local_id = ?", [.text(localID)]) { s -> PreparedItem? in
            guard let itemID = Self.text(s, 0), let manifest = Self.blob(s, 2), let tag = Self.text(s, 3) else { return nil }
            return PreparedItem(localID: localID, itemID: itemID, kind: ItemKind(rawValue: Self.text(s, 1) ?? "") ?? .photo,
                                manifest: manifest, contentTag: tag, objectIDs: objectIDs)
        }.first ?? nil
    }

    func objectsNeedingUpload() throws -> [QueueObject] {
        let ids = try rows("""
            SELECT o.object_id FROM objects o JOIN assets a ON a.local_id = o.local_id
            WHERE o.completed = 0 AND a.state = 'uploading'
            """) { Self.text($0, 0) ?? "" }
        return try ids.compactMap { try object($0) }
    }

    func assetsAwaitingFinalization() throws -> [String] {
        try rows("""
            SELECT a.local_id FROM assets a WHERE a.state IN ('uploading', 'finalizing')
            AND NOT EXISTS (SELECT 1 FROM objects o WHERE o.local_id = a.local_id AND o.completed = 0)
            """) { Self.text($0, 0) ?? "" }
    }

    // MARK: - State transitions

    func setState(_ localID: String, _ state: AssetState) throws {
        try run("UPDATE assets SET state = ?, updated_at = ? WHERE local_id = ?", [.text(state.rawValue), .double(now), .text(localID)])
    }

    /// Completed/duplicate assets keep only their record; staged file copies are returned for deletion.
    func markFinished(_ localID: String, duplicate: Bool) throws -> String? {
        try transaction {
            let staged = try rows("SELECT staged_name FROM assets WHERE local_id = ?", [.text(localID)]) { Self.text($0, 0) }.first ?? nil
            try run("DELETE FROM objects WHERE local_id = ?", [.text(localID)])
            try run("UPDATE assets SET state = ?, manifest = NULL, last_error = NULL, staged_name = NULL, updated_at = ? WHERE local_id = ?",
                    [.text(duplicate ? AssetState.duplicate.rawValue : AssetState.completed.rawValue), .double(now), .text(localID)])
            return staged
        }
    }

    /// Back to the queue; prepared data is discarded. Returns chunk file names to delete.
    func requeue(_ localID: String, error: String?, retryAfter: Date?, countAttempt: Bool) throws -> [String] {
        try transaction {
            let names = try rows("SELECT c.file_name FROM chunks c JOIN objects o ON o.object_id = c.object_id WHERE o.local_id = ?", [.text(localID)]) { Self.text($0, 0) ?? "" }
            try run("DELETE FROM objects WHERE local_id = ?", [.text(localID)])
            try run("UPDATE assets SET state = 'pending', item_id = NULL, manifest = NULL, content_tag = NULL, last_error = ?, retry_after = ?, attempts = attempts + ?, updated_at = ? WHERE local_id = ?",
                    [error.map { .text($0) } ?? .null, .double(retryAfter?.timeIntervalSince1970 ?? 0), .int(countAttempt ? 1 : 0), .double(now), .text(localID)])
            return names
        }
    }

    func markFailed(_ localID: String, error: String) throws -> [String] {
        try transaction {
            let names = try rows("SELECT c.file_name FROM chunks c JOIN objects o ON o.object_id = c.object_id WHERE o.local_id = ?", [.text(localID)]) { Self.text($0, 0) ?? "" }
            try run("DELETE FROM objects WHERE local_id = ?", [.text(localID)])
            try run("UPDATE assets SET state = 'failed', manifest = NULL, last_error = ?, attempts = attempts + 1, updated_at = ? WHERE local_id = ?",
                    [.text(error), .double(now), .text(localID)])
            return names
        }
    }

    func noteError(_ localID: String, _ error: String) throws {
        try run("UPDATE assets SET last_error = ?, updated_at = ? WHERE local_id = ?", [.text(error), .double(now), .text(localID)])
    }

    func attempts(_ localID: String) throws -> Int {
        try rows("SELECT attempts FROM assets WHERE local_id = ?", [.text(localID)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    /// Crash/termination recovery: assets interrupted while encrypting start over.
    func resetInterruptedPreparation() throws -> [String] {
        let ids = try rows("SELECT local_id FROM assets WHERE state = 'preparing'") { Self.text($0, 0) ?? "" }
        var names: [String] = []
        for id in ids { names += try requeue(id, error: nil, retryAfter: nil, countAttempt: false) }
        return names
    }

    @discardableResult
    func retryFailed() throws -> Int {
        try run("UPDATE assets SET state = 'pending', attempts = 0, retry_after = 0, last_error = NULL, updated_at = ? WHERE state = 'failed'", [.double(now)])
    }

    func retry(_ localID: String) throws {
        try run("UPDATE assets SET state = 'pending', attempts = 0, retry_after = 0, last_error = NULL, updated_at = ? WHERE local_id = ? AND state = 'failed'",
                [.double(now), .text(localID)])
    }

    /// Cancel: discard all in-flight work (assets go back to waiting). Returns chunk files to delete
    /// and server upload ids to cancel.
    func cancelInFlight() throws -> (files: [String], uploads: [String]) {
        try transaction {
            let names = try rows("SELECT file_name FROM chunks") { Self.text($0, 0) ?? "" }
            let uploads = try rows("SELECT upload_id FROM objects WHERE completed = 0 AND upload_id IS NOT NULL") { Self.text($0, 0) ?? "" }
            try run("DELETE FROM objects WHERE local_id IN (SELECT local_id FROM assets WHERE state IN ('preparing','uploading','finalizing'))")
            try run("UPDATE assets SET state = 'pending', item_id = NULL, manifest = NULL, content_tag = NULL, updated_at = ? WHERE state IN ('preparing','uploading','finalizing')", [.double(now)])
            return (names, uploads)
        }
    }

    // MARK: - Reporting

    func counts() throws -> QueueCounts {
        var counts = QueueCounts()
        for (state, count) in try rows("SELECT state, COUNT(*) FROM assets GROUP BY state", map: { (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))) }) {
            switch AssetState(rawValue: state) {
            case .pending: counts.pending += count
            case .preparing, .uploading, .finalizing: counts.active += count
            case .completed, .duplicate: counts.completed += count
            case .failed: counts.failed += count
            case nil: break
            }
        }
        return counts
    }

    func assets(states: [AssetState], limit: Int, offset: Int) throws -> [QueueAsset] {
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        return try rows("SELECT \(Self.assetColumns) FROM assets WHERE state IN (\(placeholders)) ORDER BY updated_at DESC LIMIT ? OFFSET ?",
                        states.map { .text($0.rawValue) } + [.int(Int64(limit)), .int(Int64(offset))], map: Self.asset)
    }

    func asset(_ localID: String) throws -> QueueAsset? {
        try rows("SELECT \(Self.assetColumns) FROM assets WHERE local_id = ?", [.text(localID)], map: Self.asset).first
    }

    /// Assets between preparation and server confirmation (bounds how far encryption runs ahead).
    func inFlightAssetCount() throws -> Int {
        try rows("SELECT COUNT(*) FROM assets WHERE state IN ('preparing','uploading','finalizing')") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    /// Assets and chunks waiting for a retry time in the future.
    func waitingRetryCounts() throws -> (assets: Int, chunks: Int) {
        let assets = try rows("SELECT COUNT(*) FROM assets WHERE state = 'pending' AND retry_after > ?", [.double(now)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        let chunks = try rows("SELECT COUNT(*) FROM chunks WHERE done = 0 AND retry_after > ?", [.double(now)]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        return (assets, chunks)
    }

    /// Plaintext bytes of everything backed up (or found already backed up) from this device.
    func completedBytes() throws -> Int64 {
        try rows("SELECT COALESCE(SUM(total_bytes), 0) FROM assets WHERE state IN ('completed','duplicate')") { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func pendingChunkBytes() throws -> Int64 {
        try rows("SELECT COALESCE(SUM(size), 0) FROM chunks WHERE done = 0") { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    /// Bytes still to back up. Sizes are known once an asset was exported (and for
    /// files); for photos/videos not read yet, the average size of already measured
    /// assets of the same kind is used, so the estimate is byte-based rather than a
    /// file count.
    func remainingBytesEstimate() throws -> Int64 {
        let remaining = "('pending','preparing','uploading','finalizing')"
        let known = try rows("SELECT COALESCE(SUM(total_bytes), 0) FROM assets WHERE state IN \(remaining) AND total_bytes > 0") { sqlite3_column_int64($0, 0) }.first ?? 0
        let unknown = try rows("SELECT kind, COUNT(*) FROM assets WHERE state IN \(remaining) AND (total_bytes IS NULL OR total_bytes <= 0) GROUP BY kind") {
            (Self.text($0, 0) ?? "", sqlite3_column_int64($0, 1))
        }
        guard !unknown.isEmpty else { return known }
        let averages = try rows("SELECT kind, AVG(total_bytes) FROM assets WHERE total_bytes > 0 GROUP BY kind") {
            (Self.text($0, 0) ?? "", sqlite3_column_double($0, 1))
        }
        var byKind: [String: Double] = [:]
        for (kind, average) in averages { byKind[kind] = average }
        let fallback: [String: Double] = ["photo": 3_000_000, "livePhoto": 6_000_000, "video": 60_000_000, "file": 5_000_000]
        let estimated = unknown.reduce(0.0) { sum, entry in
            sum + Double(entry.1) * (byKind[entry.0] ?? fallback[entry.0] ?? 3_000_000)
        }
        return known + Int64(estimated)
    }

    func completedLocalIDs() throws -> Set<String> {
        Set(try rows("SELECT local_id FROM assets WHERE state IN ('completed','duplicate') AND source = 'photos'") { Self.text($0, 0) ?? "" })
    }

    func referencedChunkNames() throws -> Set<String> {
        Set(try rows("SELECT file_name FROM chunks") { Self.text($0, 0) ?? "" })
    }

    func referencedStagedNames() throws -> Set<String> {
        Set(try rows("SELECT staged_name FROM assets WHERE staged_name IS NOT NULL") { Self.text($0, 0) ?? "" })
    }

    // MARK: - Meta

    func metaData(_ key: String) throws -> Data? {
        try rows("SELECT value FROM meta WHERE key = ?", [.text(key)]) { Self.blob($0, 0) }.first ?? nil
    }

    func setMetaData(_ key: String, _ value: Data?) throws {
        if let value {
            try run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .blob(value)])
        } else {
            try run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func metaInt(_ key: String) throws -> Int64? {
        guard let data = try metaData(key), let text = String(data: data, encoding: .utf8) else { return nil }
        return Int64(text)
    }

    func setMetaInt(_ key: String, _ value: Int64) throws {
        try setMetaData(key, Data(String(value).utf8))
    }

    func reset() throws {
        try run("DELETE FROM chunks")
        try run("DELETE FROM objects")
        try run("DELETE FROM assets")
        try run("DELETE FROM meta")
    }
}
