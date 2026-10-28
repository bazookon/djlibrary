import DJCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player
    @State private var showBPMPopover = false
    @State private var bpmText = ""
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.source) {
                Label("Toda la biblioteca", systemImage: "music.note.list").tag(Source.all)
                Label("Archivos añadidos", systemImage: "folder").tag(Source.files)
                Section("Playlists de Engine") {
                    OutlineGroup(model.playlists, children: \.children) { pl in
                        Label(pl.title, systemImage: pl.children == nil ? "music.note" : "folder")
                            .tag(Source.playlist(pl.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                DeckView()
                Divider()
                TrackTable()
                StatusBar()
            }
            .searchable(text: $model.search, prompt: "Buscar")
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).padding(4)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for p in providers {
                        if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                           let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    }
                    model.addFiles(urls)
                }
                return true
            }
            .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let noSelection = model.selection.isEmpty
        ToolbarItemGroup {
            Button { Task { await model.analyzeBPM() } } label: {
                Label("Analizar BPM", systemImage: "waveform.badge.magnifyingglass")
            }
            .help("Detecta BPM entero, cambios de tempo (transiciones), fase y compás. Selección o, sin selección, lo visible.")
            .disabled(model.analysisProgress != nil)

            Menu {
                Button("÷ 2 (mitad)") { model.scaleBPM(0.5) }
                Button("× 2 (doble)") { model.scaleBPM(2) }
                Button("Redondear") { model.roundBPM() }
                Divider()
                Button("Fijar BPM…") { showBPMPopover = true }
            } label: {
                Label("BPM", systemImage: "metronome")
            }
            .disabled(noSelection)
            .popover(isPresented: $showBPMPopover) {
                HStack {
                    TextField("BPM", text: $bpmText).frame(width: 80)
                        .onSubmit(applyBPM)
                    Button("Aplicar", action: applyBPM)
                }
                .padding()
            }

            Button { model.fromFilename() } label: {
                Label("Artista/Título desde nombre", systemImage: "text.badge.checkmark")
            }
            .help("Rellena artista y título a partir del nombre del archivo")
            .disabled(noSelection)

            Button { model.clearAlbum() } label: { Label("Quitar álbum", systemImage: "rectangle.stack.badge.minus") }
                .help("Quitar álbum")
                .disabled(noSelection)

            Menu {
                Button("Poner el nombre de la carpeta") { model.genreFromFolder() }
                Button("Quitar género") { model.clearGenre() }
            } label: {
                Label("Género", systemImage: "tag")
            }
            .help("Género: nombre de la carpeta (sin contar carpetas de año) o quitarlo")
            .disabled(noSelection)

            Button { model.setLogo() } label: { Label("Poner mi logo", systemImage: "seal") }
                .help(model.logoJPEG == nil ? "Elige tu logo en Ajustes" : "Poner mi logo como carátula")
                .disabled(noSelection || model.logoJPEG == nil)

            Button { model.removeArt() } label: { Label("Quitar carátula", systemImage: "photo.badge.minus") }
                .help("Quitar carátula")
                .disabled(noSelection)
        }
        ToolbarItemGroup {
            Button { model.selectSuspicious() } label: { Label("Seleccionar sospechosos", systemImage: "exclamationmark.triangle") }
                .help("Selecciona pistas con BPM > 140, < 70 o con decimales")
            Menu {
                Button("Exportar ahora") { Task { await model.exportRekordbox() } }
                    .disabled(model.isExporting)
                Button("Configurar rekordbox para leer el XML") { model.configureRekordbox() }
                Divider()
                Button("Abrir rekordbox") { model.openRekordbox() }
            } label: {
                Label("rekordbox", systemImage: "square.and.arrow.up")
            }
            .help("rekordbox.xml con pistas, playlists, beatgrid y cues")
            Button { model.revert() } label: { Label("Descartar", systemImage: "arrow.uturn.backward") }
                .help("Descartar cambios (de la selección, o todos si no hay selección)")
                .disabled(model.dirtyCount == 0)
            Button {
                player.stop()
                Task { await model.save() }
            } label: {
                Text(model.dirtyCount == 0 ? "Guardar" : "Guardar (\(model.dirtyCount))")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.dirtyCount == 0 || model.isSaving)
        }
    }

    private func applyBPM() {
        if let v = Double(bpmText.replacingOccurrences(of: ",", with: ".")), v > 20, v < 400 {
            model.setBPM(v)
            showBPMPopover = false
        }
    }
}

struct TrackTable: View {
    @Environment(LibraryModel.self) private var model
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var model = model
        Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("") { item in
                Circle()
                    .fill(item.error != nil ? Color.red : item.isDirty ? Color.orange : Color.clear)
                    .frame(width: 8, height: 8)
                    .help(item.error ?? (item.isDirty ? "Cambios sin guardar" : ""))
            }
            .width(14)

            TableColumn("Onda") { item in
                if let w = model.waveform(for: item.id) {
                    WaveformView(waveform: w, perf: model.performance(for: item.id)).frame(height: 22)
                }
            }
            .width(min: 80, ideal: 130)

            TableColumn("Archivo", value: \.filename) { item in
                Text(item.filename).foregroundStyle(.secondary).lineLimit(1).help(item.url.path)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Artista", value: \.edited.artist) { item in
                TextField("", text: model.binding(item.id, \.artist))
                    .foregroundStyle(item.edited.artist != item.original.artist ? .orange : .primary)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Título", value: \.edited.title) { item in
                TextField("", text: model.binding(item.id, \.title))
                    .foregroundStyle(item.edited.title != item.original.title ? .orange : .primary)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Álbum") { item in
                Text(item.original.album)
                    .strikethrough(item.edited.album.isEmpty && !item.original.album.isEmpty)
                    .foregroundStyle(item.edited.album != item.original.album ? .orange : .secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Género", value: \.edited.genre) { item in
                Text(item.edited.genre.isEmpty ? item.original.genre : item.edited.genre)
                    .strikethrough(item.edited.genre.isEmpty && !item.original.genre.isEmpty)
                    .foregroundStyle(item.edited.genre != item.original.genre ? .orange : .secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 110)

            TableColumn("BPM", value: \.bpmSort) { item in
                HStack(spacing: 4) {
                    if item.bpmChanged, let old = item.original.bpm {
                        Text(TagWriter.formatBPM(old)).strikethrough().foregroundStyle(.secondary)
                    }
                    if let label = model.tempoLabel(item.id) {
                        Text(label).foregroundStyle(.orange).help("Cambio de tempo detectado (pendiente de guardar)")
                    } else {
                        TextField("", text: model.bpmBinding(item.id))
                            .foregroundStyle(item.bpmChanged || item.gridEdited ? .orange : item.isSuspicious ? .yellow : .primary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .width(min: 70, ideal: 100)

            TableColumn("Carátula") { item in
                ArtBadge(state: item.edited.art, changed: item.edited.art != item.original.art)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            if let id = ids.first {
                Button("Escuchar") { player.play(id) }
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([id]) }
            }
        } primaryAction: { ids in
            // Doble clic: escuchar.
            if let id = model.visible.first(where: { ids.contains($0.id) })?.id { player.play(id) }
        }
        .onKeyPress(.space) {
            guard !isEditingText else { return .ignored }
            if let url = model.playTarget, url != player.url {
                player.play(url)
            } else {
                player.toggle()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "12345678")) { press in
            // Igual que los pads: si el cue existe salta; si está vacío lo pone aquí.
            guard !isEditingText, let url = player.url, let n = Int(press.characters) else { return .ignored }
            let perf = model.performance(for: url)
            if let cue = perf?.hotCues.first(where: { $0.index == n - 1 }) {
                player.jump(to: cue.seconds)
            } else {
                let quantize = UserDefaults.standard.object(forKey: "deckQuantize") as? Bool ?? true
                let t = player.now
                model.setHotCue(n - 1, at: quantize ? (perf?.quantize(t) ?? t) : t, in: url)
            }
            return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), !isEditingText else { return .ignored }
            player.skip(-10)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard press.modifiers.contains(.option), !isEditingText else { return .ignored }
            player.skip(10)
            return .handled
        }
    }

    /// True mientras hay un campo de texto en edición (el field editor de AppKit tiene el foco);
    /// entonces espacio y ⌥←/→ deben llegar al campo, no al reproductor.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }
}

struct ArtBadge: View {
    let state: ArtState
    let changed: Bool

    var body: some View {
        Group {
            switch state {
            case .logo: Label("Logo", systemImage: "seal.fill")
            case .other: Label("Otra", systemImage: "photo")
            case .none: Label("—", systemImage: "photo.badge.minus")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(changed ? .orange : .secondary)
    }
}

struct StatusBar: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        HStack {
            Text("\(model.visible.count) pistas · \(model.selection.count) seleccionadas")
            if model.dirtyCount > 0 && model.engineIsRunning {
                Label("Cierra Engine DJ para guardar", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            Spacer()
            RekordboxStatus()
            if let p = model.analysisProgress {
                ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 80)
                Text("Analizando \(p.done)/\(p.total)").monospacedDigit()
            }
            if model.isSaving || model.isExporting { ProgressView().controlSize(.small) }
            if let msg = model.message { Text(msg).lineLimit(1) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Estado del rekordbox.xml en la barra inferior.
struct RekordboxStatus: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        Group {
            if !model.rekordboxConfigured {
                Button("rekordbox sin configurar") { model.configureRekordbox() }
                    .buttonStyle(.link)
                    .help("Apunta rekordbox a este XML (con rekordbox cerrado)")
            } else if let date = model.lastRekordboxExport {
                Label("rekordbox.xml \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .help(model.autoExportRekordbox ? "Se actualiza solo al guardar o cuando cambia Engine" : "Exportación automática desactivada")
            }
        }
    }
}
