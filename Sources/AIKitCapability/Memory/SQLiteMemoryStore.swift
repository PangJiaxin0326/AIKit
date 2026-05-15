import Foundation
import SQLite3
import AIKitCore

/// Owns the raw `sqlite3` handle and closes it exactly once on deallocation.
/// The pointer never escapes actor isolation, so the unchecked conformance is
/// sound; it exists only because `OpaquePointer` is not `Sendable`.
private final class SQLiteConnection: @unchecked Sendable {
    let db: OpaquePointer
    init(db: OpaquePointer) { self.db = db }
    deinit { sqlite3_close(db) }
}

/// SQLite-backed `MemoryStore` with no third-party dependencies. Uses the
/// system `sqlite3` C library directly.
public actor SQLiteMemoryStore: MemoryStore {
    public enum StoreError: Error, Sendable {
        case open(String)
        case prepare(String)
        case step(String)
    }

    private let connection: SQLiteConnection
    private var db: OpaquePointer { connection.db }
    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    /// - Parameter path: file path, or `nil` for an in-memory database.
    public init(path: String? = nil) throws {
        let target = path ?? ":memory:"
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw StoreError.open(message)
        }
        try Self.createSchema(in: handle)
        self.connection = SQLiteConnection(db: handle)
    }

    private static func createSchema(in db: OpaquePointer) throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            view TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw StoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func append(_ event: UsageEvent) async throws {
        let sql = "INSERT OR REPLACE INTO usage_events (id, ts, view, kind, payload) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, event.id.uuidString, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, event.viewID.rawValue, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, event.kind.rawValue, -1, Self.transient)
        try event.payload.withUnsafeBytes { raw in
            let bound = sqlite3_bind_blob(
                stmt, 5, raw.baseAddress, Int32(raw.count), Self.transient
            )
            guard bound == SQLITE_OK else {
                throw StoreError.step(String(cString: sqlite3_errmsg(db)))
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func recent(limit: Int, view: ViewContext.ID?) async throws -> [UsageEvent] {
        var sql = "SELECT id, ts, view, kind, payload FROM usage_events"
        if view != nil { sql += " WHERE view = ?" }
        sql += " ORDER BY ts DESC LIMIT ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var nextIndex: Int32 = 1
        if let view {
            sqlite3_bind_text(stmt, nextIndex, view.rawValue, -1, Self.transient)
            nextIndex += 1
        }
        sqlite3_bind_int(stmt, nextIndex, Int32(max(0, limit)))
        return readRows(stmt)
    }

    public func search(query: String, limit: Int) async throws -> [UsageEvent] {
        guard !query.isEmpty else { return [] }
        // Escape LIKE metacharacters so a query containing `%` or `_` is
        // treated literally instead of matching everything.
        let sql = """
        SELECT id, ts, view, kind, payload FROM usage_events
        WHERE payload LIKE ? ESCAPE '\\' OR kind LIKE ? ESCAPE '\\'
        ORDER BY ts DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, pattern, -1, Self.transient)
        sqlite3_bind_int(stmt, 3, Int32(max(0, limit)))
        return readRows(stmt)
    }

    private func readRows(_ stmt: OpaquePointer?) -> [UsageEvent] {
        var results: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let viewC = sqlite3_column_text(stmt, 2),
                let kindC = sqlite3_column_text(stmt, 3),
                let uuid = UUID(uuidString: String(cString: idC)),
                let kind = UsageEvent.Kind(rawValue: String(cString: kindC))
            else { continue }

            let ts = sqlite3_column_double(stmt, 1)
            let viewID = ViewContext.ID(String(cString: viewC))
            let payload: Data
            if let blob = sqlite3_column_blob(stmt, 4) {
                let count = Int(sqlite3_column_bytes(stmt, 4))
                payload = Data(bytes: blob, count: count)
            } else {
                payload = Data()
            }
            results.append(UsageEvent(
                id: uuid,
                timestamp: Date(timeIntervalSince1970: ts),
                viewID: viewID,
                kind: kind,
                payload: payload
            ))
        }
        return results
    }
}
