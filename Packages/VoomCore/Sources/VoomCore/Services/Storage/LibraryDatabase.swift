import Foundation
import SQLite3
import os

private let dbLogger = Logger(subsystem: "com.voom.app", category: "LibraryDatabase")

/// SQLite-backed persistence for the recording library.
///
/// Each entity is stored as one row holding the full Codable JSON blob —
/// mutations are per-row upserts/deletes instead of rewriting a monolithic
/// JSON file, a single corrupt row can no longer wipe the whole library, and
/// WAL mode makes concurrent access from the app and the `voom` CLI safe.
///
/// All SQLite access is serialized on a private queue; JSON encode/decode of
/// rows happens on that queue too, keeping it off the main thread.
public final class LibraryDatabase: @unchecked Sendable {

    public enum DatabaseError: Error {
        case openFailed(String)
        case statementFailed(String)
    }

    public static let fileName = ".library.sqlite"

    private let queue = DispatchQueue(label: "voom.library.db", qos: .utility)
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent(Self.fileName)
        try queue.sync {
            try openAndMigrate(at: dbURL)
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func openAndMigrate(at url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(percentEncoded: false), &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw DatabaseError.openFailed(msg)
        }
        db = handle
        // WAL allows a reader (CLI) and writer (app) across processes;
        // busy_timeout retries briefly instead of failing on contention.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA busy_timeout=2000")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS recordings (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                json TEXT NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_recordings_created ON recordings(created_at DESC)")
        try exec("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS tags (id TEXT PRIMARY KEY, json TEXT NOT NULL)")
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw DatabaseError.statementFailed("\(msg) — \(sql.prefix(60))")
        }
    }

    // MARK: - Load

    /// Loads every row. Rows that fail to decode are skipped and logged —
    /// one bad row must never take the library down with it.
    public func loadAll() -> (recordings: [Recording], folders: [Folder], tags: [RecordingTag]) {
        queue.sync {
            let recordings: [Recording] = rows("SELECT json FROM recordings ORDER BY created_at DESC")
            let folders: [Folder] = rows("SELECT json FROM folders")
            let tags: [RecordingTag] = rows("SELECT json FROM tags")
            return (recordings, folders, tags)
        }
    }

    private func rows<T: Decodable>(_ sql: String) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLogger.error("[Voom] prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let json = String(cString: cString)
            do {
                out.append(try decoder.decode(T.self, from: Data(json.utf8)))
            } catch {
                dbLogger.error("[Voom] Skipping undecodable \(T.self) row: \(error.localizedDescription)")
            }
        }
        return out
    }

    // MARK: - Writes (async on the db queue)

    public func upsertRecording(_ recording: Recording) {
        queue.async { [self] in
            upsert(table: "recordings", id: recording.id.uuidString, value: recording,
                   extraColumn: ("created_at", recording.createdAt.timeIntervalSince1970))
        }
    }

    public func deleteRecording(id: UUID) {
        queue.async { [self] in
            delete(table: "recordings", id: id.uuidString)
        }
    }

    public func upsertFolder(_ folder: Folder) {
        queue.async { [self] in
            upsert(table: "folders", id: folder.id.uuidString, value: folder)
        }
    }

    public func deleteFolder(id: UUID) {
        queue.async { [self] in
            delete(table: "folders", id: id.uuidString)
        }
    }

    public func upsertTag(_ tag: RecordingTag) {
        queue.async { [self] in
            upsert(table: "tags", id: tag.id.uuidString, value: tag)
        }
    }

    public func deleteTag(id: UUID) {
        queue.async { [self] in
            delete(table: "tags", id: id.uuidString)
        }
    }

    /// Bulk replace, used by the one-time JSON migration and bulk mutations.
    public func replaceAllRecordings(_ recordings: [Recording]) {
        queue.async { [self] in
            do {
                try exec("BEGIN IMMEDIATE")
                try exec("DELETE FROM recordings")
                for r in recordings {
                    upsert(table: "recordings", id: r.id.uuidString, value: r,
                           extraColumn: ("created_at", r.createdAt.timeIntervalSince1970))
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                dbLogger.error("[Voom] replaceAllRecordings failed: \(error.localizedDescription)")
            }
        }
    }

    /// Blocks until every queued write has hit the database. Quit path.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: - Row primitives (must run on `queue`)

    private func upsert<T: Encodable>(table: String, id: String, value: T, extraColumn: (name: String, value: Double)? = nil) {
        let json: String
        do {
            json = String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            dbLogger.error("[Voom] Encode failed for \(table)/\(id): \(error.localizedDescription)")
            return
        }

        let sql: String
        if let extraColumn {
            sql = "INSERT INTO \(table) (id, \(extraColumn.name), json) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET \(extraColumn.name) = excluded.\(extraColumn.name), json = excluded.json"
        } else {
            sql = "INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            dbLogger.error("[Voom] upsert prepare failed: \(String(cString: sqlite3_errmsg(self.db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        if let extraColumn {
            sqlite3_bind_double(stmt, 2, extraColumn.value)
            sqlite3_bind_text(stmt, 3, json, -1, transient)
        } else {
            sqlite3_bind_text(stmt, 2, json, -1, transient)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            dbLogger.error("[Voom] upsert failed for \(table)/\(id): \(String(cString: sqlite3_errmsg(self.db)))")
        }
    }

    private func delete(table: String, id: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM \(table) WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        if sqlite3_step(stmt) != SQLITE_DONE {
            dbLogger.error("[Voom] delete failed for \(table)/\(id): \(String(cString: sqlite3_errmsg(self.db)))")
        }
    }
}
