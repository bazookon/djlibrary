import Foundation
import SQLite3

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var text: String? {
        switch self {
        case .text(let v): return v
        case .int(let v): return String(v)
        default: return nil
        }
    }

    var blob: Data? {
        switch self {
        case .blob(let v): return v
        case .text(let v): return Data(v.utf8)
        default: return nil
        }
    }
}

public struct SQLiteError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Wrapper mínimo sobre la API C de SQLite.
final class SQLite {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no se pudo abrir"
            sqlite3_close(db)
            throw SQLiteError(message: "No se pudo abrir \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
            var row: [SQLValue] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        row.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    func exec(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    var lastInsertId: Int64 { sqlite3_last_insert_rowid(db) }
}
