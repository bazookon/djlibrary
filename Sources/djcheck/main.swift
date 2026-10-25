import DJCore
import Foundation

// Herramienta de prueba del núcleo. Usar SIEMPRE sobre copias.
//   djcheck parse <nombre>...
//   djcheck grid <EngineLibraryCopia> <trackId> [bpm]
//   djcheck tag <archivoCopia> <título> <artista> <bpm> [logo]

let args = CommandLine.arguments.dropFirst()

func run() async throws {
    switch args.first {
    case "parse":
        for name in args.dropFirst() {
            let p = FilenameParser.parse(name)
            print("\(name)\n  artista: \(p.artist ?? "—")\n  título:  \(p.title)")
        }
    case "grid":
        let a = Array(args)
        let root = URL(fileURLWithPath: a[1])
        let id = Int64(a[2])!
        if a.count > 3, let bpm = Double(a[3]) {
            let db = try EngineDatabase(libraryRoot: root, readOnly: false)
            var c = EngineChange(trackId: id)
            c.bpm = bpm
            try db.apply([c])
        }
        let db = try EngineDatabase(libraryRoot: root, readOnly: true)
        guard let beats = try db.beatData(trackId: id) else { print("sin beatData"); return }
        print("sr \(beats.sampleRate) samples \(beats.totalSamples) anchor \(beats.anchor)")
        print("default  \(BeatData.bpm(of: beats.defaultGrid, sampleRate: beats.sampleRate) ?? 0) \(beats.defaultGrid)")
        print("adjusted \(BeatData.bpm(of: beats.adjustedGrid, sampleRate: beats.sampleRate) ?? 0) \(beats.adjustedGrid)")
        let t = try db.tracks().first { $0.id == id }
        print("track bpm \(t?.bpm ?? 0)")
    case "tag":
        let a = Array(args)
        let url = URL(fileURLWithPath: a[1])
        var e = TagEdits()
        e.title = a[2]
        e.artist = a[3]
        e.bpm = Double(a[4])
        e.clearAlbum = true
        e.genre = ProcessInfo.processInfo.environment["DJ_GENRE"]
        if a.count > 5 { e.artwork = .jpeg(try Artwork.prepareLogo(from: URL(fileURLWithPath: a[5]))) }
        let size = try await TagWriter.write(url, e)
        let back = try await TagWriter.read(url)
        print("escrito \(size) bytes → título \(back.title ?? "—"), artista \(back.artist ?? "—"), álbum \(back.album ?? "—"), bpm \(back.bpm ?? 0)")
    default:
        print("uso: djcheck parse|grid|tag …")
    }
}

do { try await run() } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
