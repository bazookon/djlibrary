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
    case "rekordbox":
        let a = Array(args)
        let db = try EngineDatabase(libraryRoot: URL(fileURLWithPath: a[1]), readOnly: true)
        let s = try RekordboxExport.export(from: db, to: URL(fileURLWithPath: a[2]))
        print("pistas \(s.tracks), playlists \(s.playlists), hot cues \(s.cues)")
    case "rbsettings":
        let a = Array(args)
        let settings = URL(fileURLWithPath: a[1])
        print("antes:", RekordboxSettings.isConfigured(xmlPath: a[2], settings: settings))
        try RekordboxSettings.configure(xmlPath: a[2], settings: settings)
        print("después:", RekordboxSettings.isConfigured(xmlPath: a[2], settings: settings))
    case "dump":
        // djcheck dump <EngineLibrary> <trackId> <archivo> <desde> <hasta> <salida>: columnas y beats en texto
        let a = Array(args)
        let w = try DetailWaveform.compute(url: URL(fileURLWithPath: a[3]))
        let perf = try EngineDatabase(libraryRoot: URL(fileURLWithPath: a[1]), readOnly: true).performance(trackId: Int64(a[2])!)
        let from = Double(a[4])!, to = Double(a[5])!
        var out = "cps \(w.columnsPerSecond)\n"
        for i in Int(from * w.columnsPerSecond)..<Int(to * w.columnsPerSecond) {
            out += "c \(w.amplitude[i]) \(w.low[i]) \(w.mid[i]) \(w.high[i])\n"
        }
        for b in perf?.beats(from: from, to: to) ?? [] { out += "b \(b.seconds - from) \(b.beat)\n" }
        try out.write(toFile: a[6], atomically: true, encoding: .utf8)
    case "bpmtest":
        // djcheck bpmtest <carpeta> [máx]: compara con el BPM del nombre ("128-98", "128 - 095", "104 A 120 BPM", "085 …")
        let a = Array(args)
        let dir = URL(fileURLWithPath: a[1])
        let limit = a.count > 2 ? Int(a[2]) ?? 1000 : 1000
        let exts: Set<String> = ["mp3", "wav", "aif", "aiff", "m4a"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var ok = 0, total = 0, okStart = 0, okEnd = 0
        for f in files.prefix(limit) {
            guard let exp = expectedBPM(f.lastPathComponent) else { continue }
            total += 1
            let t0 = Date()
            guard let r = try? TempoDetector.analyze(url: f) else {
                print("· no se pudo leer \(f.lastPathComponent)")
                total -= 1
                continue
            }
            let got = r.segments.map { Int($0.bpm.rounded()) }
            let first = got.first ?? 0, last = got.last ?? 0
            let s1 = abs(first - exp.0) <= 1, s2 = abs(last - exp.1) <= 1
            if s1 { okStart += 1 }
            if s2 { okEnd += 1 }
            let wanted = exp.0 == exp.1 ? 1 : 2
            let pass = s1 && s2 && got.count == wanted
            if pass { ok += 1 }
            let segs = r.segments.map { "\(Int($0.bpm))@\(Int($0.start))s" }.joined(separator: " → ")
            print("\(pass ? "✓" : "✗") esperado \(exp.0)\(exp.0 != exp.1 ? "→\(exp.1)" : "")  detectado \(segs)  (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)  \(f.lastPathComponent.prefix(60))")
        }
        print("ACIERTO \(ok)/\(total)  inicio \(okStart)  final \(okEnd)")
    case "bpmdebug":
        for w in try TempoDetector.windows(url: URL(fileURLWithPath: Array(args)[1])) {
            print(String(format: "%5.0fs  %3d  (2º %3d)  pico/media %.2f", w.time, w.bpm, w.second, w.confidence))
        }
    case "gridtest":
        // djcheck gridtest <EngineLibrary> <carpeta>: fase del beat y compás frente al grid de Engine (tempo constante)
        let a = Array(args)
        let db = try EngineDatabase(libraryRoot: URL(fileURLWithPath: a[1]), readOnly: true)
        let byPath = Dictionary(try db.tracks().map { ($0.url.path, $0.id) }, uniquingKeysWith: { x, _ in x })
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: a[2]), includingPropertiesForKeys: nil)
            .filter { ["mp3", "wav", "aif", "aiff", "m4a"].contains($0.pathExtension.lowercased()) }
        var n = 0, phaseOK = 0, barOK = 0
        var errors: [Double] = []
        var barHist = [0, 0, 0, 0]
        for f in files {
            guard let id = byPath[f.standardizedFileURL.path], let perf = try db.performance(trackId: id), perf.grid.count == 2,
                  let r = try? TempoDetector.analyze(url: f), r.segments.count == 1 else { continue }
            let g0 = perf.grid[0], g1 = perf.grid[1]
            let spbE = (g1.position - g0.position) / Double(g1.beat - g0.beat) / perf.sampleRate
            let seg = r.segments[0]
            guard abs(60 / spbE - seg.bpm) < 0.6 else { continue }
            n += 1
            let anchorE = g0.position / perf.sampleRate - Double(g0.beat) * spbE   // beat 0 de Engine
            let spb = 60 / seg.bpm
            let beats = (seg.firstBeat - anchorE) / spb
            let frac = beats - beats.rounded()
            errors.append(frac * spb * 1000)
            if abs(frac * spb) < 0.025 { phaseOK += 1 }
            let ourDown = Int(beats.rounded()) + seg.downbeatOffset
            if ((ourDown % 4) + 4) % 4 == 0 { barOK += 1 }
            barHist[((ourDown % 4) + 4) % 4] += 1
            if n <= 8 {
                print(String(format: "  primer beat nuestro %.3f s (índice Engine %d), downbeat +%d → índice %d; beat 0 de Engine %.3f s  %@",
                             seg.firstBeat, Int(beats.rounded()), seg.downbeatOffset, ourDown, anchorE, String(f.lastPathComponent.prefix(40))))
            }
        }
        errors.sort()
        let abs = errors.map { Swift.abs($0) }.sorted()
        print("pistas \(n)  fase < 25 ms: \(phaseOK)  compás igual que Engine: \(barOK)  error mediano \(abs.isEmpty ? 0 : Int(abs[abs.count / 2])) ms")
        print("diferencia de compás con Engine (beats 0/1/2/3):", barHist)
        print("error con signo (ms), percentiles 10/25/50/75/90:", [0.1, 0.25, 0.5, 0.75, 0.9].map { Int(errors[Int(Double(errors.count - 1) * $0)]) })
    case "analyzewrite":
        // djcheck analyzewrite <EngineLibraryCopia> <trackId> <archivo>: analiza y escribe el grid en la copia
        let a = Array(args)
        let root = URL(fileURLWithPath: a[1]), id = Int64(a[2])!
        let r = try TempoDetector.analyze(url: URL(fileURLWithPath: a[3]))
        print("tramos:", r.segments.map { String(format: "%.0f BPM desde %.1fs (1º beat %.3f, compás +%d)", $0.bpm, $0.start, $0.firstBeat, $0.downbeatOffset) })
        var c = EngineChange(trackId: id)
        c.bpm = r.segments.first?.bpm
        c.segments = r.segments
        try EngineDatabase(libraryRoot: root, readOnly: false).apply([c])
        let perf = try EngineDatabase(libraryRoot: root, readOnly: true).performance(trackId: id)!
        for (m, n) in zip(perf.grid, perf.grid.dropFirst()) {
            print(String(format: "  beat %4d @ %7.3fs → %4d beats → %.2f BPM", m.beat, m.position / perf.sampleRate, n.beat - m.beat,
                         60 * perf.sampleRate * Double(n.beat - m.beat) / (n.position - m.position)))
        }
        print("rekordbox:", RekordboxExport.tempos(perf).map { String(format: "%.2f@%.3f (beat %d)", $0.bpm, $0.start, $0.beat) })
    case "detail":
        let start = Date()
        let w = try DetailWaveform.compute(url: URL(fileURLWithPath: Array(args)[1]))
        print("columnas \(w.amplitude.count), \(String(format: "%.1f", w.columnsPerSecond))/s, duración \(String(format: "%.1f", w.duration)) s, en \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    case "cues":
        // djcheck cues <EngineLibraryCopia> <trackId>: reescribe los cues tal cual + añade H en el beat más cercano a 30 s
        let a = Array(args)
        let root = URL(fileURLWithPath: a[1]), id = Int64(a[2])!
        let before = try EngineDatabase(libraryRoot: root, readOnly: true).performance(trackId: id)!
        print("antes:", before.hotCues.map { "\($0.index):\($0.label)@\(String(format: "%.3f", $0.seconds))" }, "main", before.mainCue ?? -1, "default", before.defaultMainCue ?? -1)
        var p = before
        p.hotCues.append(.new(index: 7, seconds: p.quantize(30)))
        p.mainCue = p.quantize(1)
        var c = EngineChange(trackId: id)
        c.cues = p
        try EngineDatabase(libraryRoot: root, readOnly: false).apply([c])
        let after = try EngineDatabase(libraryRoot: root, readOnly: true).performance(trackId: id)!
        print("después:", after.hotCues.map { "\($0.index):\($0.label)@\(String(format: "%.3f", $0.seconds))" }, "main", after.mainCue ?? -1, "default", after.defaultMainCue ?? -1)
    default:
        print("uso: djcheck parse|grid|tag|rekordbox|rbsettings|detail|cues …")
    }
}

/// BPM esperado según el nombre: (inicio, final). Para pistas sin transición inicio == final.
func expectedBPM(_ name: String) -> (Int, Int)? {
    let base = (name as NSString).deletingPathExtension
    func valid(_ s: Substring) -> Int? { Int(s).flatMap { $0 >= 60 && $0 <= 200 ? $0 : nil } }
    let pairs = [#"(\d{2,3})\s*(?:-|–|\s[Aa]\s)\s*0?(\d{2,3})"#, #"^(\d{2,3})\s+(\d{2,3})\s"#]
    for p in pairs {
        if let r = try? NSRegularExpression(pattern: p),
           let m = r.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let r1 = Range(m.range(at: 1), in: base), let r2 = Range(m.range(at: 2), in: base),
           let x = valid(base[r1]), let y = valid(base[r2]) {
            return (x, y)
        }
    }
    if let r = base.range(of: #"^\(?0?(\d{2,3})\)?[\s.\-]"#, options: .regularExpression) {
        let digits = base[r].filter(\.isNumber)
        if let v = valid(Substring(digits)) { return (v, v) }
    }
    if let r = base.range(of: #"(\d{2,3})\s*bpm"#, options: [.regularExpression, .caseInsensitive]) {
        let digits = base[r].filter(\.isNumber)
        if let v = valid(Substring(digits)) { return (v, v) }
    }
    return nil
}

do { try await run() } catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
