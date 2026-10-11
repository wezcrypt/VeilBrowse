import Foundation
import SQLite3

enum SyncState: String, Sendable, CaseIterable, Identifiable {
    case pending
    case uploading
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .uploading: return String(localized: "Uploading")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct SyncRecord: Sendable, Identifiable, Hashable {
    let localID: String
    let kind: MediaKind
    let createdAt: Date?
    var state: SyncState
    var sha256: String?
    var uploadID: String?
    var remoteMediaID: String?
    var bytes: Int64?
    var filename: String?
    var attempts: Int
    var lastError: String?
    var updatedAt: Date

    var id: String { localID }
}

struct SyncCounts: Sendable, Equatable {
    var pending = 0
    var uploading = 0
    var completed = 0
    var failed = 0

    var total: Int { pending + uploading + completed + failed }
    var remaining: Int { pending + uploading }

    func count(for state: SyncState) -> Int {
        switch state {
        case .pending: return pending
        case .uploading: return uploading
        case .completed: return completed
        case .failed: return failed
        }
    }
}

enum SyncStoreError: Error, LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        if case .sqlite(let message) = self { return "Sync database error: \(message)" }
        return nil
    }
}

/// Owns the sqlite3 connection and closes it when released.
private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

/// Persistent per-asset sync state in SQLite (handles 100k+ assets with indexed queries).
actor SyncStore {
    private enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case null
    }

    private let handle: SQLiteHandle
    private var db: OpaquePointer? { handle.pointer }

    /// `path` is a file path, or ":memory:" for an ephemeral store.
    init(path: String) throws {
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if path != ":memory:" { flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SyncStoreError.sqlite(message)
        }
        self.handle = SQLiteHandle(handle)
        try Self.migrate(handle)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SyncStoreError.sqlite(message)
        }
    }

    private static func migrate(_ db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        var version: Int32 = 0
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        if version < 1 {
            try exec(db, """
            BEGIN;
            CREATE TABLE IF NOT EXISTS assets (
                local_id TEXT PRIMARY KEY,
                media_kind TEXT NOT NULL,
                created_at REAL,
                state TEXT NOT NULL,
                sha256 TEXT,
                upload_id TEXT,
                remote_media_id TEXT,
                bytes INTEGER,
                filename TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                retry_after REAL NOT NULL DEFAULT 0,
                seen_generation INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS ix_assets_state_created ON assets(state, created_at DESC);
            CREATE INDEX IF NOT EXISTS ix_assets_state_updated ON assets(state, updated_at DESC);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB);
            PRAGMA user_version = 1;
            COMMIT;
            """)
        }
    }

    // MARK: - Low-level helpers

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        guard let db else { throw SyncStoreError.sqlite("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SyncStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SyncStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func rows<T>(_ sql: String, _ values: [Value] = [], map: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                output.append(map(statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SyncStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        return output
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    private static let recordColumns = "local_id, media_kind, created_at, state, sha256, upload_id, remote_media_id, bytes, filename, attempts, last_error, updated_at"

    private static func record(_ statement: OpaquePointer) -> SyncRecord {
        let created = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return SyncRecord(
            localID: text(statement, 0) ?? "",
            kind: MediaKind(rawValue: text(statement, 1) ?? "") ?? .photo,
            createdAt: created,
            state: SyncState(rawValue: text(statement, 3) ?? "") ?? .pending,
            sha256: text(statement, 4),
            uploadID: text(statement, 5),
            remoteMediaID: text(statement, 6),
            bytes: optionalInt(statement, 7),
            filename: text(statement, 8),
            attempts: Int(sqlite3_column_int(statement, 9)),
            lastError: text(statement, 10),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
        )
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: - Scanning

    func nextGeneration() throws -> Int64 {
        let current = try metaInt("scan.generation") ?? 0
        try setMetaInt("scan.generation", current + 1)
        return current + 1
    }

    /// Inserts newly discovered assets as pending and marks existing ones as seen.
    @discardableResult
    func upsertScanned(_ assets: [ScannedAsset], generation: Int64) throws -> Int {
        var inserted = 0
        let timestamp = now
        try transaction {
            for asset in assets {
                let existing = try rows("SELECT 1 FROM assets WHERE local_id = ?", [.text(asset.localIdentifier)]) { _ in true }
                if existing.isEmpty {
                    try run(
                        "INSERT INTO assets(local_id, media_kind, created_at, state, seen_generation, updated_at) VALUES (?,?,?,?,?,?)",
                        [.text(asset.localIdentifier), .text(asset.kind.rawValue),
                         asset.creationDate.map { .double($0.timeIntervalSince1970) } ?? .null,
                         .text(SyncState.pending.rawValue), .int(generation), .double(timestamp)]
                    )
                    inserted += 1
                } else {
                    try run("UPDATE assets SET seen_generation = ? WHERE local_id = ?", [.int(generation), .text(asset.localIdentifier)])
                }
            }
        }
        return inserted
    }

    /// Removes pending/failed rows for assets that disappeared from the library
    /// (deleted, or no longer visible under Limited access). Completed rows stay:
    /// those items are safe on the server.
    func pruneUnseen(generation: Int64) throws {
        try run("DELETE FROM assets WHERE seen_generation != ? AND state IN ('pending','failed')", [.int(generation)])
    }

    func removeDeleted(_ localIDs: [String]) throws {
        try transaction {
            for id in localIDs {
                try run("DELETE FROM assets WHERE local_id = ? AND state IN ('pending','failed')", [.text(id)])
            }
        }
    }

    // MARK: - Queue

    func nextPending(limit: Int, kinds: [MediaKind], excluding: Set<String>) throws -> [SyncRecord] {
        guard !kinds.isEmpty else { return [] }
        let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
        var values: [Value] = [.text(SyncState.pending.rawValue), .double(now)]
        values += kinds.map { .text($0.rawValue) }
        values.append(.int(Int64(limit + excluding.count)))
        let candidates = try rows(
            "SELECT \(Self.recordColumns) FROM assets WHERE state = ? AND retry_after <= ? AND media_kind IN (\(placeholders)) ORDER BY created_at DESC LIMIT ?",
            values,
            map: Self.record
        )
        return Array(candidates.filter { !excluding.contains($0.localID) }.prefix(limit))
    }

    func earliestRetryDate(kinds: [MediaKind]) throws -> Date? {
        guard !kinds.isEmpty else { return nil }
        let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
        let values: [Value] = [.text(SyncState.pending.rawValue)] + kinds.map { .text($0.rawValue) }
        return try rows("SELECT MIN(retry_after) FROM assets WHERE state = ? AND media_kind IN (\(placeholders))", values) { statement -> Date? in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }.first ?? nil
    }

    func record(_ localID: String) throws -> SyncRecord? {
        try rows("SELECT \(Self.recordColumns) FROM assets WHERE local_id = ?", [.text(localID)], map: Self.record).first
    }

    func markUploading(_ localID: String) throws {
        try run("UPDATE assets SET state = 'uploading', updated_at = ? WHERE local_id = ?", [.double(now), .text(localID)])
    }

    func updateFileInfo(_ localID: String, sha256: String, bytes: Int64, filename: String) throws {
        try run(
            "UPDATE assets SET sha256 = ?, bytes = ?, filename = ?, updated_at = ? WHERE local_id = ?",
            [.text(sha256), .int(bytes), .text(filename), .double(now), .text(localID)]
        )
    }

    func setUploadID(_ localID: String, uploadID: String?) throws {
        try run("UPDATE assets SET upload_id = ?, updated_at = ? WHERE local_id = ?", [uploadID.map { .text($0) } ?? .null, .double(now), .text(localID)])
    }

    func markCompleted(_ localID: String, remoteMediaID: String) throws {
        try run(
            "UPDATE assets SET state = 'completed', remote_media_id = ?, upload_id = NULL, last_error = NULL, retry_after = 0, updated_at = ? WHERE local_id = ?",
            [.text(remoteMediaID), .double(now), .text(localID)]
        )
    }

    /// Returns to the queue. `countAttempt` is false for interruptions (pause, network loss).
    func markPending(_ localID: String, error: String?, retryAfter: Date?, countAttempt: Bool) throws {
        try run(
            "UPDATE assets SET state = 'pending', last_error = ?, retry_after = ?, attempts = attempts + ?, updated_at = ? WHERE local_id = ?",
            [error.map { .text($0) } ?? .null, .double(retryAfter?.timeIntervalSince1970 ?? 0), .int(countAttempt ? 1 : 0), .double(now), .text(localID)]
        )
    }

    func markFailed(_ localID: String, error: String) throws {
        try run(
            "UPDATE assets SET state = 'failed', last_error = ?, attempts = attempts + 1, updated_at = ? WHERE local_id = ?",
            [.text(error), .double(now), .text(localID)]
        )
    }

    func clearHash(_ localID: String) throws {
        try run("UPDATE assets SET sha256 = NULL, upload_id = NULL WHERE local_id = ?", [.text(localID)])
    }

    @discardableResult
    func retryAllFailed() throws -> Int {
        let count = try counts().failed
        try run("UPDATE assets SET state = 'pending', attempts = 0, retry_after = 0, last_error = NULL, updated_at = ? WHERE state = 'failed'", [.double(now)])
        return count
    }

    func retry(_ localID: String) throws {
        try run(
            "UPDATE assets SET state = 'pending', attempts = 0, retry_after = 0, last_error = NULL, updated_at = ? WHERE local_id = ? AND state = 'failed'",
            [.double(now), .text(localID)]
        )
    }

    /// Rows left in `uploading` by a crash or termination go back to the queue.
    func resetStaleUploading() throws {
        try run("UPDATE assets SET state = 'pending' WHERE state = 'uploading'")
    }

    // MARK: - Reporting

    func counts() throws -> SyncCounts {
        var counts = SyncCounts()
        for (state, count) in try rows("SELECT state, COUNT(*) FROM assets GROUP BY state", map: { (Self.text($0, 0) ?? "", Int(sqlite3_column_int64($0, 1))) }) {
            switch SyncState(rawValue: state) {
            case .pending: counts.pending = count
            case .uploading: counts.uploading = count
            case .completed: counts.completed = count
            case .failed: counts.failed = count
            case nil: break
            }
        }
        return counts
    }

    func records(state: SyncState, limit: Int, offset: Int) throws -> [SyncRecord] {
        let order = state == .pending ? "created_at DESC" : "updated_at DESC"
        return try rows(
            "SELECT \(Self.recordColumns) FROM assets WHERE state = ? ORDER BY \(order) LIMIT ? OFFSET ?",
            [.text(state.rawValue), .int(Int64(limit)), .int(Int64(offset))],
            map: Self.record
        )
    }

    func averageCompletedBytes() throws -> Int64? {
        try rows("SELECT AVG(bytes) FROM assets WHERE state = 'completed' AND bytes IS NOT NULL") { statement -> Int64? in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Int64(sqlite3_column_double(statement, 0))
        }.first ?? nil
    }

    func completedBytes() throws -> Int64 {
        try rows("SELECT COALESCE(SUM(bytes), 0) FROM assets WHERE state = 'completed'") { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func completedLocalIDs() throws -> Set<String> {
        Set(try rows("SELECT local_id FROM assets WHERE state = 'completed'") { Self.text($0, 0) ?? "" })
    }

    // MARK: - Meta

    func metaData(_ key: String) throws -> Data? {
        try rows("SELECT value FROM meta WHERE key = ?", [.text(key)]) { statement -> Data? in
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }.first ?? nil
    }

    func setMetaData(_ key: String, _ value: Data?) throws {
        guard let db else { return }
        if let value {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", -1, &statement, nil) == SQLITE_OK else {
                throw SyncStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(value.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SyncStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
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

    /// Clears every row (used on sign-out so a different vault starts clean).
    func reset() throws {
        try run("DELETE FROM assets")
        try run("DELETE FROM meta")
    }
}
