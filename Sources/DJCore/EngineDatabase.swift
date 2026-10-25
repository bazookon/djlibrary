import Foundation

public struct EngineTrack: Identifiable, Hashable {
    public let id: Int64
    public let url: URL
    public var title: String?
    public var artist: String?
    public var album: String?
    public var bpm: Double?
    public var albumArtId: Int64?
    /// SHA1 de la imagen embebida (Engine guarda solo el hash; la imagen la lee del archivo).
    public var artHash: Data?
    public var genre: String?
}

public final class EnginePlaylist: Identifiable, Hashable {
    public let id: Int64
    public let title: String
    public var children: [EnginePlaylist]?

    init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }

    public static func == (a: EnginePlaylist, b: EnginePlaylist) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Cambio a aplicar sobre una pista de Engine. Los campos nil no se tocan.
public struct EngineChange {
    public var trackId: Int64
    public var title: String?
    public var artist: String?
    public var clearAlbum = false
    /// "" quita el género.
    public var genre: String?
    public var bpm: Double?
    public var artwork: ArtworkChange?
    public var fileBytes: Int64?

    public init(trackId: Int64) { self.trackId = trackId }
}

public enum ArtworkChange: Equatable {
    case remove
    /// Imagen ya embebida en el archivo; Engine la identifica por su SHA1.
    case image(sha1: Data)
}

/// Acceso a la base de datos principal de Engine DJ (Database2/m.db).
public final class EngineDatabase {
    public let libraryRoot: URL
    let db: SQLite

    public static var defaultLibraryRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Engine Library")
    }

    public static func databaseURL(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("Database2/m.db")
    }

    public init(libraryRoot: URL = EngineDatabase.defaultLibraryRoot, readOnly: Bool) throws {
        self.libraryRoot = libraryRoot
        db = try SQLite(path: Self.databaseURL(libraryRoot: libraryRoot).path, readOnly: readOnly)
    }

    /// Copia m.db (y su journal si existe) a "Engine Library/DJLibrary Backups".
    @discardableResult
    public static func backup(libraryRoot: URL) throws -> URL {
        let fm = FileManager.default
        let dir = libraryRoot.appendingPathComponent("DJLibrary Backups", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let src = databaseURL(libraryRoot: libraryRoot)
        let dst = dir.appendingPathComponent("m-\(stamp).db")
        try fm.copyItem(at: src, to: dst)
        let journal = URL(fileURLWithPath: src.path + "-journal")
        if fm.fileExists(atPath: journal.path) {
            try? fm.copyItem(at: journal, to: URL(fileURLWithPath: dst.path + "-journal"))
        }
        return dst
    }

    // MARK: Lectura

    public func tracks() throws -> [EngineTrack] {
        let rows = try db.query("""
            SELECT t.id, t.path, t.title, t.artist, t.album, t.bpmAnalyzed, t.bpm, t.albumArtId, a.hash, t.genre
            FROM Track t LEFT JOIN AlbumArt a ON a.id = t.albumArtId
            WHERE t.path IS NOT NULL AND t.path != ''
            """)
        return rows.map { r in
            EngineTrack(
                id: r[0].int ?? 0,
                url: URL(fileURLWithPath: r[1].text ?? "", relativeTo: libraryRoot).standardizedFileURL,
                title: r[2].text,
                artist: r[3].text,
                album: r[4].text,
                bpm: r[5].double ?? r[6].double,
                albumArtId: r[7].int,
                artHash: r[8].blob.flatMap { $0.isEmpty ? nil : $0 },
                genre: r[9].text)
        }
    }

    /// Árbol de playlists en el orden de Engine (lista enlazada por nextListId).
    public func playlists() throws -> [EnginePlaylist] {
        let rows = try db.query("SELECT id, title, parentListId, nextListId FROM Playlist")
        var byParent: [Int64: [(id: Int64, next: Int64)]] = [:]
        var nodes: [Int64: EnginePlaylist] = [:]
        for r in rows {
            let id = r[0].int ?? 0
            nodes[id] = EnginePlaylist(id: id, title: r[1].text ?? "")
            byParent[r[2].int ?? 0, default: []].append((id, r[3].int ?? 0))
        }
        func ordered(_ parent: Int64) -> [EnginePlaylist]? {
            guard let siblings = byParent[parent], !siblings.isEmpty else { return nil }
            let ids = linkedOrder(siblings.map { ($0.id, $0.next) })
            return ids.compactMap { id in
                let node = nodes[id]
                node?.children = ordered(id)
                return node
            }
        }
        return ordered(0) ?? []
    }

    public func trackIds(inPlaylist listId: Int64) throws -> [Int64] {
        let rows = try db.query("SELECT id, trackId, nextEntityId FROM PlaylistEntity WHERE listId = ?", [.int(listId)])
        var trackFor: [Int64: Int64] = [:]
        for r in rows { trackFor[r[0].int ?? 0] = r[1].int ?? 0 }
        return linkedOrder(rows.map { ($0[0].int ?? 0, $0[2].int ?? 0) }).compactMap { trackFor[$0] }
    }

    public func beatData(trackId: Int64) throws -> BeatData? {
        let rows = try db.query("SELECT beatData FROM PerformanceData WHERE trackId = ?", [.int(trackId)])
        guard let blob = rows.first?.first?.blob, !blob.isEmpty else { return nil }
        return try BeatData(blob: blob)
    }

    // MARK: Escritura

    public func apply(_ changes: [EngineChange]) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            for c in changes { try apply(c) }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private func apply(_ c: EngineChange) throws {
        let id = SQLValue.int(c.trackId)
        if let title = c.title { try db.exec("UPDATE Track SET title = ? WHERE id = ?", [.text(title), id]) }
        if let artist = c.artist { try db.exec("UPDATE Track SET artist = ? WHERE id = ?", [.text(artist), id]) }
        if c.clearAlbum { try db.exec("UPDATE Track SET album = NULL WHERE id = ?", [id]) }
        if let genre = c.genre {
            try db.exec("UPDATE Track SET genre = ? WHERE id = ?", [genre.isEmpty ? .null : .text(genre), id])
        }
        if let bytes = c.fileBytes { try db.exec("UPDATE Track SET fileBytes = ? WHERE id = ?", [.int(bytes), id]) }

        if let bpm = c.bpm {
            try db.exec("UPDATE Track SET bpm = ?, bpmAnalyzed = ? WHERE id = ?",
                        [.int(Int64(bpm.rounded())), .double(bpm), id])
            if var beats = try beatData(trackId: c.trackId) {
                beats.setConstantBPM(bpm)
                try db.exec("UPDATE PerformanceData SET beatData = ? WHERE trackId = ?", [.blob(try beats.encoded()), id])
            }
        }

        switch c.artwork {
        case .remove:
            try db.exec("UPDATE Track SET albumArtId = ? WHERE id = ?", [.int(try emptyArtId()), id])
        case .image(let sha1):
            try db.exec("UPDATE Track SET albumArtId = ? WHERE id = ?", [.int(try artId(for: sha1)), id])
        case nil:
            break
        }
    }

    private func emptyArtId() throws -> Int64 {
        if let id = try db.query("SELECT id FROM AlbumArt WHERE hash IS NULL ORDER BY id LIMIT 1").first?.first?.int {
            return id
        }
        try db.exec("INSERT INTO AlbumArt (hash, albumArt) VALUES (NULL, NULL)")
        return db.lastInsertId
    }

    private func artId(for sha1: Data) throws -> Int64 {
        if let id = try db.query("SELECT id FROM AlbumArt WHERE hash = ? LIMIT 1", [.blob(sha1)]).first?.first?.int {
            return id
        }
        try db.exec("INSERT INTO AlbumArt (hash, albumArt) VALUES (?, NULL)", [.blob(sha1)])
        return db.lastInsertId
    }
}

/// Ordena nodos de una lista enlazada (id, siguienteId); siguiente 0 = fin.
/// Si la cadena está rota, añade los restantes por id.
func linkedOrder(_ nodes: [(id: Int64, next: Int64)]) -> [Int64] {
    let next = Dictionary(nodes.map { ($0.id, $0.next) }, uniquingKeysWith: { a, _ in a })
    let pointedTo = Set(nodes.map(\.next))
    var result: [Int64] = []
    var seen = Set<Int64>()
    var cur = nodes.map(\.id).sorted().first { !pointedTo.contains($0) }
    while let c = cur, !seen.contains(c), next[c] != nil {
        result.append(c)
        seen.insert(c)
        cur = next[c]
    }
    result += nodes.map(\.id).sorted().filter { !seen.contains($0) }
    return result
}
