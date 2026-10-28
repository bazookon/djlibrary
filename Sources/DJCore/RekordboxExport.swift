import Foundation

/// Exporta la biblioteca de Engine a un rekordbox.xml (Preferencias → Avanzado → Base de datos → rekordbox xml).
public enum RekordboxExport {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Pioneer/rekordbox/rekordbox.xml")
    }

    /// Índice de tonalidad de Engine (Track.key) → notación de rekordbox.
    static let keys = ["C", "Am", "G", "Em", "D", "Bm", "A", "F#m", "E", "C#m", "B", "G#m",
                       "F#", "D#m", "Db", "Bbm", "Ab", "Fm", "Eb", "Cm", "Bb", "Gm", "F", "Dm"]

    public struct Summary {
        public let tracks: Int
        public let playlists: Int
        public let cues: Int
    }

    @discardableResult
    public static func export(from db: EngineDatabase, to url: URL) throws -> Summary {
        let rows = try db.db.query("""
            SELECT id, path, title, artist, album, genre, length, bpmAnalyzed, bpm, key, bitrate,
                   fileBytes, year, comment, label, remixer, composer, fileType, rating
            FROM Track WHERE path IS NOT NULL AND path != ''
            """)
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <DJ_PLAYLISTS Version="1.0.0">
              <PRODUCT Name="DJ Library" Version="0.1" Company="Dj O!"/>
              <COLLECTION Entries="\(rows.count)">

            """
        var exported = Set<Int64>()
        var cueCount = 0
        for r in rows {
            guard let id = r[0].int, let path = r[1].text else { continue }
            let file = URL(fileURLWithPath: path, relativeTo: db.libraryRoot).standardizedFileURL
            let perf = try? db.performance(trackId: id)
            let bpm = r[7].double ?? r[8].double ?? 0
            var attrs: [(String, String)] = [
                ("TrackID", String(id)),
                ("Name", r[2].text ?? file.deletingPathExtension().lastPathComponent),
                ("Artist", r[3].text ?? ""),
                ("Composer", r[16].text ?? ""),
                ("Album", r[4].text ?? ""),
                ("Genre", r[5].text ?? ""),
                ("Kind", kind(file.pathExtension)),
                ("Size", String(r[11].int ?? 0)),
                ("TotalTime", String(r[6].int ?? 0)),
                ("Year", (r[12].int).map { $0 > 0 ? String($0) : "" } ?? ""),
                ("AverageBpm", String(format: "%.2f", bpm)),
                ("BitRate", String(r[10].int ?? 0)),
                ("SampleRate", String(Int(perf?.sampleRate ?? 44100))),
                ("Comments", r[13].text ?? ""),
                ("Rating", String(rating(r[18].int ?? 0))),
                ("Location", location(file)),
                ("Remixer", r[15].text ?? ""),
                ("Tonality", (r[9].int).flatMap { $0 >= 0 && $0 < 24 ? keys[Int($0)] : nil } ?? ""),
                ("Label", r[14].text ?? ""),
            ]
            attrs.removeAll { $0.1.isEmpty && !["Name", "Artist"].contains($0.0) }
            xml += "    <TRACK " + attrs.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ") + ">\n"
            if let perf {
                for t in tempos(perf) {
                    xml += "      <TEMPO Inizio=\"\(fmt(t.start))\" Bpm=\"\(String(format: "%.2f", t.bpm))\" Metro=\"4/4\" Battito=\"\(t.beat)\"/>\n"
                }
                if let main = perf.mainCue {
                    xml += mark(name: "", type: 0, start: main, end: nil, num: -1, color: nil)
                }
                for cue in perf.hotCues {
                    xml += mark(name: cue.label, type: 0, start: cue.seconds, end: nil, num: cue.index, color: cue.color)
                    // Copia como memory cue: los CDJ sin hot cues en pantalla también los ven.
                    xml += mark(name: cue.label, type: 0, start: cue.seconds, end: nil, num: -1, color: nil)
                    cueCount += 1
                }
                for loop in perf.loops {
                    xml += mark(name: loop.label, type: 4, start: loop.start, end: loop.end, num: -1, color: nil)
                }
            }
            xml += "    </TRACK>\n"
            exported.insert(id)
        }
        xml += "  </COLLECTION>\n  <PLAYLISTS>\n"

        let tree = try db.playlists()
        var playlistCount = 0
        func node(_ pl: EnginePlaylist, indent: String) throws -> String {
            let tracks = try db.trackIds(inPlaylist: pl.id).filter { exported.contains($0) }
            let name = escape(pl.title)
            if let children = pl.children, !children.isEmpty {
                // En rekordbox una carpeta no puede tener pistas: van a una playlist hija con el mismo nombre.
                var inner = try children.map { try node($0, indent: indent + "  ") }
                if !tracks.isEmpty { inner.insert(playlist(name, tracks, indent: indent + "  "), at: 0) }
                playlistCount += 1
                return "\(indent)<NODE Type=\"0\" Name=\"\(name)\" Count=\"\(inner.count)\">\n" + inner.joined() + "\(indent)</NODE>\n"
            }
            playlistCount += 1
            return playlist(name, tracks, indent: indent)
        }
        let roots = try tree.map { try node($0, indent: "      ") }
        xml += "    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(roots.count)\">\n" + roots.joined() + "    </NODE>\n"
        xml += "  </PLAYLISTS>\n</DJ_PLAYLISTS>\n"

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(xml.utf8).write(to: url, options: .atomic)
        return Summary(tracks: exported.count, playlists: playlistCount, cues: cueCount)
    }

    private static func playlist(_ name: String, _ tracks: [Int64], indent: String) -> String {
        "\(indent)<NODE Name=\"\(name)\" Type=\"1\" KeyType=\"0\" Entries=\"\(tracks.count)\">\n"
            + tracks.map { "\(indent)  <TRACK Key=\"\($0)\"/>\n" }.joined()
            + "\(indent)</NODE>\n"
    }

    private static func mark(name: String, type: Int, start: Double, end: Double?, num: Int, color: CueColor?) -> String {
        var s = "      <POSITION_MARK Name=\"\(escape(name))\" Type=\"\(type)\" Start=\"\(fmt(start))\""
        if let end { s += " End=\"\(fmt(end))\"" }
        s += " Num=\"\(num)\""
        if let color { s += " Red=\"\(color.red)\" Green=\"\(color.green)\" Blue=\"\(color.blue)\"" }
        return s + "/>\n"
    }

    public struct Tempo { public let start: Double; public let bpm: Double; public let beat: Int }

    /// Un TEMPO por tramo del grid de Engine (uno solo si el grid es constante), desde el primer beat ≥ 0.
    public static func tempos(_ perf: TrackPerformance) -> [Tempo] {
        var out: [Tempo] = []
        let sr = perf.sampleRate
        let pairs = Array(zip(perf.grid, perf.grid.dropFirst()))
        for (i, (a, b)) in pairs.enumerated() where b.beat > a.beat {
            let spb = (b.position - a.position) / Double(b.beat - a.beat)
            guard spb > 0 else { continue }
            // Puentes de ≤ 4 beats entre dos tramos (los pone nuestro detector en el break): rekordbox sigue con el
            // tempo anterior hasta el siguiente TEMPO, que es lo que suena.
            if b.beat - a.beat <= 4 && i > 0 && i < pairs.count - 1 { continue }
            let bpm = 60 * sr / spb
            if let last = out.last, abs(last.bpm - bpm) < 0.01 { continue }
            var beat = a.beat
            if a.position < 0 { beat += Int64((-a.position / spb).rounded(.up)) }
            guard beat < b.beat else { continue }
            let start = (a.position + Double(beat - a.beat) * spb) / sr
            out.append(Tempo(start: start, bpm: bpm, beat: Int(((beat % 4) + 4) % 4) + 1))
        }
        return out
    }

    static func kind(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": return "MP3 File"
        case "wav", "wave": return "WAV File"
        case "aif", "aiff": return "AIFF File"
        case "m4a", "mp4", "aac": return "M4A File"
        case "flac": return "FLAC File"
        default: return ext.uppercased() + " File"
        }
    }

    /// Engine puntúa 0–100; rekordbox usa 0, 51, 102, 153, 204, 255 (0–5 estrellas).
    static func rating(_ engine: Int64) -> Int {
        [0, 51, 102, 153, 204, 255][max(0, min(5, Int((Double(engine) / 20).rounded())))]
    }

    static func location(_ url: URL) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "&#?;")
        return "file://localhost" + (url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path)
    }

    static func fmt(_ seconds: Double) -> String { String(format: "%.3f", max(0, seconds)) }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Caracteres de control no son válidos en XML 1.0.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }
}
