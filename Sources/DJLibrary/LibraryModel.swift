import AppKit
import DJCore
import Observation
import SwiftUI

enum Source: Hashable {
    case all
    case files
    case playlist(Int64)
}

enum ArtState: Equatable {
    case none, logo, other
}

struct Meta: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var bpm: Double?
    var art: ArtState = .none
}

struct TrackItem: Identifiable {
    let id: URL
    var engineId: Int64?
    var original: Meta
    var edited: Meta
    var error: String?
    /// Hot cues / cue principal editados en el deck (pendientes de guardar).
    var cuesEdited = false
    /// Grid nuevo del motor de BPM (pendiente de guardar).
    var gridEdited = false

    var url: URL { id }
    var filename: String { id.lastPathComponent }
    var isDirty: Bool { original != edited || cuesEdited || gridEdited }
    var bpmSort: Double { edited.bpm ?? 0 }
    var bpmChanged: Bool { original.bpm != edited.bpm }

    /// BPM sospechoso de estar mal analizado: doble/mitad o con decimales.
    var isSuspicious: Bool {
        guard let bpm = edited.bpm else { return true }
        return bpm > 140 || bpm < 70 || abs(bpm - bpm.rounded()) > 0.02
    }
}

@MainActor
@Observable
final class LibraryModel {
    var playlists: [EnginePlaylist] = []
    var source: Source? = .all { didSet { refreshVisible() } }
    var search = "" { didSet { refreshVisible() } }
    var selection = Set<URL>()
    var sortOrder = [KeyPathComparator(\TrackItem.bpmSort)] { didSet { refreshVisible() } }
    private(set) var visible: [TrackItem] = []
    var message: String?
    var isSaving = false

    private(set) var logoJPEG: Data?
    private var logoHash: Data?
    private var items: [URL: TrackItem] = [:]
    private var engineTracks: [Int64: EngineTrack] = [:]
    private var playlistTrackIds: [Int64] = []
    private var addedFiles: [URL] = []
    private var backedUp = false
    @ObservationIgnored private var readDB: EngineDatabase?
    @ObservationIgnored private var waveforms: [Int64: Waveform?] = [:]
    @ObservationIgnored private var performances: [Int64: TrackPerformance?] = [:]

    @ObservationIgnored @AppStorage("libraryRoot") var libraryRootPath = EngineDatabase.defaultLibraryRoot.path
    @ObservationIgnored @AppStorage("writeFileTags") var writeFileTags = true

    var libraryRoot: URL { URL(fileURLWithPath: libraryRootPath) }
    var dirtyCount: Int { items.values.filter(\.isDirty).count }

    static var logoURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DJLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("logo.jpg")
    }

    init() {
        if let data = try? Data(contentsOf: Self.logoURL) { setLogoData(data) }
        load()
        startWatchingEngine()
    }

    // MARK: Carga

    func load() {
        do {
            let db = try EngineDatabase(libraryRoot: libraryRoot, readOnly: true)
            readDB = db
            waveforms = [:]
            performances = [:]
            playlists = try db.playlists()
            let tracks = try db.tracks()
            engineTracks = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            duplicateEngineTracks = 0
            for t in tracks.sorted(by: { $0.id < $1.id }) {
                // Una sola entrada por archivo físico: Engine tiene alguna pista repetida con otra forma de la ruta.
                let k = Self.key(t.url)
                if let first = urlByKey[k], first != t.url {
                    duplicateEngineTracks += 1
                    continue
                }
                urlByKey[k] = t.url
                let meta = meta(for: t)
                if var existing = items[t.url] {
                    existing.engineId = t.id
                    if !existing.isDirty { existing.edited = meta }
                    existing.original = meta
                    items[t.url] = existing
                } else {
                    items[t.url] = TrackItem(id: t.url, engineId: t.id, original: meta, edited: meta)
                }
            }
            message = nil
        } catch {
            message = "No se pudo abrir la biblioteca de Engine: \(error.localizedDescription)"
        }
        refreshVisible()
    }

    private func meta(for t: EngineTrack) -> Meta {
        let art: ArtState = t.artHash == nil ? .none : (t.artHash == logoHash ? .logo : .other)
        return Meta(title: t.title ?? "", artist: t.artist ?? "", album: t.album ?? "", genre: t.genre ?? "", bpm: t.bpm, art: art)
    }

    func refreshVisible() {
        var urls: [URL]
        switch source {
        case .all, nil:
            urls = Array(Set(engineTracks.values.map { canonical($0.url) }))
        case .files:
            urls = addedFiles
        case .playlist(let id):
            if let db = try? EngineDatabase(libraryRoot: libraryRoot, readOnly: true),
               let ids = try? db.trackIds(inPlaylist: id) {
                playlistTrackIds = ids
            }
            var seen = Set<URL>()
            urls = playlistTrackIds.compactMap { engineTracks[$0].map { canonical($0.url) } }.filter { seen.insert($0).inserted }
        }
        var list = urls.compactMap { items[$0] }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.filename.localizedCaseInsensitiveContains(q) || $0.edited.title.localizedCaseInsensitiveContains(q)
                    || $0.edited.artist.localizedCaseInsensitiveContains(q)
            }
        }
        visible = list.sorted(using: sortOrder)
    }

    /// Archivos o carpetas soltados en la ventana.
    func addFiles(_ urls: [URL]) {
        let exts: Set<String> = ["mp3", "wav", "wave", "aif", "aiff", "m4a", "mp4", "aac", "flac"]
        var found: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if exts.contains(f.pathExtension.lowercased()) { found.append(f.standardizedFileURL) }
                }
            } else if exts.contains(url.pathExtension.lowercased()) {
                found.append(url.standardizedFileURL)
            }
        }
        var added = 0, repeated = 0, inEngine = 0
        for raw in found {
            // Misma pista aunque llegue con otra forma de la ruta (acentos NFD de Finder, mayúsculas).
            let k = Self.key(raw)
            let url = urlByKey[k] ?? raw
            urlByKey[k] = url
            if addedFiles.contains(url) { repeated += 1; continue }
            addedFiles.append(url)
            added += 1
            if items[url] == nil {
                items[url] = TrackItem(id: url, engineId: nil, original: Meta(), edited: Meta())
                Task { await loadFileTags(url) }
            } else if items[url]?.engineId != nil {
                inEngine += 1
            }
        }
        source = .files
        var parts = ["Añadidas \(added) pistas"]
        if inEngine > 0 { parts.append("\(inEngine) ya están en Engine (se editan allí también)") }
        if repeated > 0 { parts.append("\(repeated) ya estaban en la lista y no se repiten") }
        message = parts.joined(separator: "; ") + "."
    }

    private func loadFileTags(_ url: URL) async {
        guard let tags = try? await TagWriter.read(url), var item = items[url], item.engineId == nil else { return }
        let meta = Meta(title: tags.title ?? "", artist: tags.artist ?? "", album: tags.album ?? "", genre: tags.genre ?? "",
                        bpm: tags.bpm, art: .other)
        item.original = meta
        item.edited = meta
        items[url] = item
        refreshVisible()
    }

    /// Forma de onda de Engine (solo pistas analizadas por Engine); se cachea al dibujarse.
    func waveform(for url: URL) -> Waveform? {
        guard let id = items[url]?.engineId else { return nil }
        if let cached = waveforms[id] { return cached }
        let w = try? readDB?.waveform(trackId: id)
        waveforms[id] = w
        return w
    }

    /// Cues, loops y grid de Engine de la pista (con los cues editados sin guardar, si los hay).
    func performance(for url: URL) -> TrackPerformance? {
        var perf: TrackPerformance?
        if let edited = cueEdits[url] {
            perf = edited
        } else if let id = items[url]?.engineId {
            if let cached = performances[id] {
                perf = cached
            } else {
                perf = try? readDB?.performance(trackId: id)
                performances[id] = perf
            }
        }
        // Grid pendiente del motor de BPM: se ve en el deck antes de guardar.
        if var p = perf, let analysis = gridEdits[url], p.totalSamples > 0 {
            p.grid = BeatData.markers(for: analysis.segments, sampleRate: p.sampleRate, totalSamples: p.totalSamples)
            perf = p
        }
        return perf
    }

    // MARK: Motor de BPM

    private(set) var gridEdits: [URL: TempoAnalysis] = [:]
    private(set) var analysisProgress: (done: Int, total: Int)?

    /// "128 → 98" si el análisis pendiente tiene cambios de tempo.
    func tempoLabel(_ url: URL) -> String? {
        guard let a = gridEdits[url], a.segments.count > 1 else { return nil }
        return a.segments.map { TagWriter.formatBPM($0.bpm) }.joined(separator: " → ")
    }

    /// Analiza la selección (o todo lo visible) con el motor propio: BPM enteros, cambios de tempo, fase y compás.
    /// El resultado queda pendiente (naranja) para revisarlo en el deck antes de guardar.
    func analyzeBPM() async {
        let urls = (targets.isEmpty ? visible.map(\.id) : visible.map(\.id).filter { targets.contains($0) })
        guard !urls.isEmpty, analysisProgress == nil else { return }
        analysisProgress = (0, urls.count)
        var failed = 0
        await withTaskGroup(of: (URL, TempoAnalysis?).self) { group in
            var queue = urls[...]
            for _ in 0..<min(4, queue.count) {
                let url = queue.removeFirst()
                group.addTask { (url, try? TempoDetector.analyze(url: url)) }
            }
            for await (url, result) in group {
                if let result, let first = result.segments.first {
                    gridEdits[url] = result
                    items[url]?.gridEdited = true
                    items[url]?.edited.bpm = first.bpm
                    items[url]?.error = nil
                } else {
                    failed += 1
                    items[url]?.error = "No se pudo analizar el audio"
                }
                analysisProgress = (analysisProgress?.done ?? 0) + 1 == urls.count ? nil : ((analysisProgress?.done ?? 0) + 1, urls.count)
                if let next = queue.popFirst() {
                    group.addTask { (next, try? TempoDetector.analyze(url: next)) }
                }
            }
        }
        analysisProgress = nil
        refreshVisible()
        let changes = urls.filter { items[$0]?.isDirty == true }.count
        let transitions = urls.filter { (gridEdits[$0]?.segments.count ?? 0) > 1 }.count
        message = "Analizadas \(urls.count) pistas: \(changes) con cambios, \(transitions) con cambio de tempo"
            + (failed > 0 ? ", \(failed) sin poder leer." : ". Revísalas en el deck y guarda.")
    }

    /// Un cambio manual de BPM descarta el grid del motor (se vuelve a un grid constante).
    private func dropAnalysis(_ ids: Set<URL>) {
        for id in ids {
            gridEdits[id] = nil
            items[id]?.gridEdited = false
        }
    }

    // MARK: Deck

    private(set) var cueEdits: [URL: TrackPerformance] = [:]
    private(set) var detail: (url: URL, waveform: DetailWaveform)?

    /// Calcula la onda detallada de la pista que suena (0,1–0,3 s) para la vista con zoom.
    func loadDetail(for url: URL) async {
        guard detail?.url != url else { return }
        let w = try? await Task.detached { try DetailWaveform.compute(url: url) }.value
        if let w { detail = (url, w) }
    }

    func editCues(_ url: URL, _ change: (inout TrackPerformance) -> Void) {
        guard var p = performance(for: url), items[url]?.engineId != nil else {
            message = "Los cues solo se pueden editar en pistas de Engine."
            return
        }
        change(&p)
        cueEdits[url] = p
        items[url]?.cuesEdited = true
        refreshVisible()
    }

    func setHotCue(_ index: Int, at seconds: Double, in url: URL) {
        editCues(url) { p in
            if let i = p.hotCues.firstIndex(where: { $0.index == index }) {
                p.hotCues[i].seconds = seconds
            } else {
                p.hotCues.append(.new(index: index, seconds: seconds))
            }
        }
    }

    func deleteHotCue(_ index: Int, in url: URL) {
        editCues(url) { $0.hotCues.removeAll { $0.index == index } }
    }

    func setMainCue(at seconds: Double, in url: URL) {
        editCues(url) { $0.mainCue = seconds }
    }

    // MARK: rekordbox

    @ObservationIgnored @AppStorage("rekordboxXML") var rekordboxXMLPath = RekordboxExport.defaultURL.path
    @ObservationIgnored @AppStorage("autoExportRekordbox") var autoExportRekordbox = true
    var isExporting = false
    private(set) var lastRekordboxExport: Date?
    private(set) var rekordboxConfigured = false
    @ObservationIgnored private var lastDBStamp: Date?
    @ObservationIgnored private var watchTimer: Timer?

    /// Exporta lo que hay guardado en Engine (los cambios sin guardar no entran).
    func exportRekordbox(quiet: Bool = false) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        let root = libraryRoot
        let dest = URL(fileURLWithPath: rekordboxXMLPath)
        do {
            let s = try await Task.detached {
                try RekordboxExport.export(from: EngineDatabase(libraryRoot: root, readOnly: true), to: dest)
            }.value
            lastRekordboxExport = Date()
            if !quiet {
                message = "rekordbox.xml: \(s.tracks) pistas, \(s.playlists) playlists, \(s.cues) hot cues."
                    + (dirtyCount > 0 ? " Los cambios sin guardar no están incluidos." : "")
            }
        } catch {
            message = "No se pudo exportar a rekordbox: \(error.localizedDescription)"
        }
    }

    /// Fecha de la última escritura en la base de Engine (m.db o su journal).
    private func engineDBStamp() -> Date? {
        let db = EngineDatabase.databaseURL(libraryRoot: libraryRoot)
        return [db.path, db.path + "-journal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    /// Vigila la base de Engine: si cambia (desde Engine o desde aquí), recarga la tabla
    /// y actualiza rekordbox.xml. Al arrancar, exporta si el XML es más viejo que la base.
    func startWatchingEngine() {
        refreshRekordboxConfigured()
        lastDBStamp = engineDBStamp()
        if autoExportRekordbox {
            let xmlDate = (try? FileManager.default.attributesOfItem(atPath: rekordboxXMLPath)[.modificationDate]) as? Date
            if let db = lastDBStamp, xmlDate.map({ $0 < db }) ?? true {
                Task { await exportRekordbox(quiet: true) }
            } else {
                lastRekordboxExport = xmlDate
            }
        }
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkEngineChanges() }
        }
    }

    private func checkEngineChanges() async {
        refreshRekordboxConfigured()
        guard !isSaving, let stamp = engineDBStamp(), stamp != lastDBStamp else { return }
        // Esperamos a que Engine deje de escribir unos segundos antes de leer.
        guard Date().timeIntervalSince(stamp) > 8 else { return }
        lastDBStamp = stamp
        if dirtyCount == 0 { load() }
        if autoExportRekordbox { await exportRekordbox(quiet: true) }
    }

    var rekordboxIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == RekordboxSettings.bundleIdentifier }
    }

    func refreshRekordboxConfigured() {
        rekordboxConfigured = RekordboxSettings.isConfigured(xmlPath: rekordboxXMLPath)
    }

    /// Apunta rekordbox a nuestro XML y muestra «rekordbox xml» en su barra lateral.
    func configureRekordbox() {
        guard !rekordboxIsRunning else {
            message = "Cierra rekordbox para configurarlo (guarda sus preferencias al salir y pisaría el cambio)."
            return
        }
        do {
            try RekordboxSettings.configure(xmlPath: rekordboxXMLPath)
            refreshRekordboxConfigured()
            message = "rekordbox configurado: al abrirlo verás «rekordbox xml» en la barra lateral."
        } catch {
            message = "No se pudo configurar rekordbox: \(error.localizedDescription)"
        }
    }

    func openRekordbox() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RekordboxSettings.bundleIdentifier) else {
            message = "No encuentro rekordbox en Aplicaciones."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Identidad de archivos

    /// Primera URL vista para cada archivo físico (clave normalizada).
    @ObservationIgnored private var urlByKey: [String: URL] = [:]
    private(set) var duplicateEngineTracks = 0

    /// Clave de un archivo: ruta absoluta en forma Unicode compuesta (Engine guarda NFC, Finder entrega NFD)
    /// y en minúsculas (APFS no distingue mayúsculas).
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    func canonical(_ url: URL) -> URL { urlByKey[Self.key(url)] ?? url }

    // MARK: Edición

    func binding(_ id: URL, _ path: WritableKeyPath<Meta, String>) -> Binding<String> {
        Binding(
            get: { self.items[id]?.edited[keyPath: path] ?? "" },
            set: { value in self.modify([id]) { $0.edited[keyPath: path] = value } })
    }

    func bpmBinding(_ id: URL) -> Binding<String> {
        Binding(
            get: { self.items[id]?.edited.bpm.map(TagWriter.formatBPM) ?? "" },
            set: { text in
                if let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 20, v < 400 {
                    self.dropAnalysis([id])
                    self.modify([id]) { $0.edited.bpm = v }
                }
            })
    }

    var targets: Set<URL> { selection }

    /// Primera pista seleccionada, en el orden en que se ve la tabla.
    var playTarget: URL? { visible.first { selection.contains($0.id) }?.id }

    func modify(_ ids: Set<URL>, _ change: (inout TrackItem) -> Void) {
        for id in ids {
            guard var item = items[id] else { continue }
            change(&item)
            item.error = nil
            items[id] = item
        }
        refreshVisible()
    }

    func scaleBPM(_ factor: Double) {
        dropAnalysis(targets)
        modify(targets) { if let b = $0.edited.bpm { $0.edited.bpm = b * factor } }
    }
    func roundBPM() {
        dropAnalysis(targets)
        modify(targets) { if let b = $0.edited.bpm { $0.edited.bpm = b.rounded() } }
    }
    func setBPM(_ value: Double) {
        dropAnalysis(targets)
        modify(targets) { $0.edited.bpm = value }
    }
    func clearAlbum() { modify(targets) { $0.edited.album = "" } }
    func clearGenre() { modify(targets) { $0.edited.genre = "" } }
    func genreFromFolder() { modify(targets) { if let g = FolderGenre.genre(for: $0.url) { $0.edited.genre = g } } }
    func setLogo() { modify(targets) { $0.edited.art = .logo } }
    func removeArt() { modify(targets) { $0.edited.art = .none } }
    func revert() {
        let ids = targets.isEmpty ? Set(items.keys) : targets
        for id in ids { cueEdits[id] = nil }
        dropAnalysis(ids)
        modify(ids) {
            $0.edited = $0.original
            $0.cuesEdited = false
        }
    }

    func fromFilename() {
        modify(targets) {
            let parsed = FilenameParser.parse($0.filename)
            $0.edited.title = parsed.title
            if let artist = parsed.artist { $0.edited.artist = artist }
        }
    }

    func selectSuspicious() {
        selection = Set(visible.filter(\.isSuspicious).map(\.id))
    }

    // MARK: Logo

    func chooseLogo(_ url: URL) {
        do {
            let data = try Artwork.prepareLogo(from: url)
            try data.write(to: Self.logoURL)
            setLogoData(data)
            load()
        } catch {
            message = "No se pudo usar el logo: \(error.localizedDescription)"
        }
    }

    private func setLogoData(_ data: Data) {
        logoJPEG = data
        logoHash = Artwork.sha1(data)
        // Sin la miniatura en la caché de Engine, el logo no se ve aunque esté en el archivo.
        do {
            try Artwork.ensureEngineCache(libraryRoot: libraryRoot, image: data)
        } catch {
            message = "No se pudo crear la carátula en la caché de Engine: \(error.localizedDescription)"
        }
    }

    // MARK: Guardar

    var engineIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains("Engine DJ")
                || ($0.bundleIdentifier ?? "").lowercased().contains("inmusic")
        }
    }

    func save() async {
        let dirty = items.values.filter(\.isDirty)
        guard !dirty.isEmpty else { return }
        let touchesEngine = dirty.contains { $0.engineId != nil }
        if touchesEngine && engineIsRunning {
            message = "Cierra Engine DJ antes de guardar: escribe en la misma base de datos."
            return
        }
        isSaving = true
        defer { isSaving = false }

        if touchesEngine && !backedUp {
            do {
                let dst = try EngineDatabase.backup(libraryRoot: libraryRoot)
                backedUp = true
                message = "Copia de seguridad: \(dst.lastPathComponent)"
            } catch {
                message = "No se pudo hacer la copia de seguridad de Engine; no se guardó nada. \(error.localizedDescription)"
                return
            }
        }

        var changes: [EngineChange] = []
        var failures = 0
        for item in dirty {
            let o = item.original, e = item.edited
            var edits = TagEdits()
            var change = EngineChange(trackId: item.engineId ?? 0)
            if e.title != o.title { edits.title = e.title; change.title = e.title }
            if e.artist != o.artist { edits.artist = e.artist; change.artist = e.artist }
            if e.album.isEmpty && !o.album.isEmpty { edits.clearAlbum = true; change.clearAlbum = true }
            if e.genre != o.genre { edits.genre = e.genre; change.genre = e.genre }
            if e.bpm != o.bpm, let bpm = e.bpm { edits.bpm = bpm; change.bpm = bpm }
            if e.art != o.art {
                switch e.art {
                case .logo:
                    guard let logo = logoJPEG, let hash = logoHash else { continue }
                    try? Artwork.ensureEngineCache(libraryRoot: libraryRoot, image: logo)
                    edits.artwork = .jpeg(logo)
                    change.artwork = .image(sha1: hash)
                case .none:
                    edits.artwork = .remove
                    change.artwork = .remove
                case .other:
                    break
                }
            }

            if item.cuesEdited { change.cues = cueEdits[item.id] }
            if item.gridEdited { change.segments = gridEdits[item.id]?.segments }

            let hasTagEdits = edits.title != nil || edits.artist != nil || edits.clearAlbum || edits.genre != nil
                || edits.bpm != nil || edits.artwork != nil
            if writeFileTags && hasTagEdits {
                do {
                    change.fileBytes = try await TagWriter.write(item.url, edits)
                } catch TagError.unsupported {
                    // Formato sin escritura de tags: se guarda solo en Engine.
                } catch {
                    items[item.id]?.error = error.localizedDescription
                    failures += 1
                    continue
                }
            }
            if item.engineId != nil {
                changes.append(change)
            } else {
                items[item.id]?.original = e
            }
        }

        if !changes.isEmpty {
            do {
                try EngineDatabase(libraryRoot: libraryRoot, readOnly: false).apply(changes)
            } catch {
                message = "Error escribiendo en Engine: \(error.localizedDescription)"
                return
            }
        }
        for item in dirty where items[item.id]?.error == nil {
            items[item.id]?.cuesEdited = false
            cueEdits[item.id] = nil
            items[item.id]?.gridEdited = false
            gridEdits[item.id] = nil
        }
        load()
        let saved = dirty.count - failures
        message = failures == 0 ? "Guardadas \(saved) pistas." : "Guardadas \(saved) pistas; \(failures) con error (en rojo)."
        if autoExportRekordbox && !changes.isEmpty {
            lastDBStamp = engineDBStamp()  // ya exportamos aquí; que el vigilante no repita
            await exportRekordbox(quiet: true)
            message = (message ?? "") + " rekordbox.xml actualizado."
        }
    }
}
