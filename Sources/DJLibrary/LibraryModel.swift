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

    var url: URL { id }
    var filename: String { id.lastPathComponent }
    var isDirty: Bool { original != edited }
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
    }

    // MARK: Carga

    func load() {
        do {
            let db = try EngineDatabase(libraryRoot: libraryRoot, readOnly: true)
            readDB = db
            waveforms = [:]
            playlists = try db.playlists()
            let tracks = try db.tracks()
            engineTracks = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for t in tracks {
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
            urls = engineTracks.values.map(\.url)
        case .files:
            urls = addedFiles
        case .playlist(let id):
            if let db = try? EngineDatabase(libraryRoot: libraryRoot, readOnly: true),
               let ids = try? db.trackIds(inPlaylist: id) {
                playlistTrackIds = ids
            }
            urls = playlistTrackIds.compactMap { engineTracks[$0]?.url }
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
        for url in found where !addedFiles.contains(url) {
            addedFiles.append(url)
            if items[url] == nil {
                items[url] = TrackItem(id: url, engineId: nil, original: Meta(), edited: Meta())
                Task { await loadFileTags(url) }
            }
        }
        source = .files
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

    func scaleBPM(_ factor: Double) { modify(targets) { if let b = $0.edited.bpm { $0.edited.bpm = b * factor } } }
    func roundBPM() { modify(targets) { if let b = $0.edited.bpm { $0.edited.bpm = b.rounded() } } }
    func setBPM(_ value: Double) { modify(targets) { $0.edited.bpm = value } }
    func clearAlbum() { modify(targets) { $0.edited.album = "" } }
    func clearGenre() { modify(targets) { $0.edited.genre = "" } }
    func genreFromFolder() { modify(targets) { if let g = FolderGenre.genre(for: $0.url) { $0.edited.genre = g } } }
    func setLogo() { modify(targets) { $0.edited.art = .logo } }
    func removeArt() { modify(targets) { $0.edited.art = .none } }
    func revert() { modify(targets.isEmpty ? Set(items.keys) : targets) { $0.edited = $0.original } }

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

            if writeFileTags {
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
        load()
        let saved = dirty.count - failures
        message = failures == 0 ? "Guardadas \(saved) pistas." : "Guardadas \(saved) pistas; \(failures) con error (en rojo)."
    }
}
