import DJCore
import SwiftUI

/// Deck al estilo rekordbox/Engine: vista general arriba, onda con zoom (cabezal fijo en el centro) debajo
/// y controles de cue abajo. Los cues se ponen en la posición actual, cuantizados al beat si Q está activo.
struct DeckView: View {
    @Environment(Player.self) private var player
    @Environment(LibraryModel.self) private var model
    @AppStorage("deckZoom") private var zoomIndex = 2
    @AppStorage("deckQuantize") private var quantize = true

    static let zoomLevels: [Double] = [2, 4, 8, 16, 32]   // segundos visibles
    static let letters = ["A", "B", "C", "D", "E", "F", "G", "H"]

    var body: some View {
        let url = player.url
        let perf = url.flatMap { model.performance(for: $0) }
        let detail = model.detail.flatMap { $0.url == url ? $0.waveform : nil }
        let overview = url.flatMap { model.waveform(for: $0) } ?? detail?.overview()

        VStack(spacing: 6) {
            header(perf: perf)

            if let overview, player.duration > 0 {
                OverviewStrip(waveform: overview, perf: perf)
                    .frame(height: 40)
            } else {
                Rectangle().fill(.quaternary.opacity(0.3)).frame(height: 40)
                    .overlay(Text(url == nil ? "Doble clic o espacio para escuchar una pista" : "Cargando onda…")
                        .font(.caption).foregroundStyle(.secondary))
            }

            ZoomedWaveform(detail: detail, perf: perf, zoom: Self.zoomLevels[zoomIndex])
                .frame(height: 110)

            controls(perf: perf)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: url) {
            if let url { await model.loadDetail(for: url) }
        }
    }

    // MARK: Cabecera

    private func header(perf: TrackPerformance?) -> some View {
        HStack(spacing: 12) {
            Text(nowPlaying).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let url = player.url {
                let listBPM = model.visible.first(where: { $0.id == url })?.edited.bpm
                // BPM del tramo donde está el cabezal (en transiciones cambia, p. ej. 128 → 98).
                if let bpm = perf?.bpmAt(player.currentTime) ?? listBPM {
                    Text(TagWriter.formatBPM(bpm) + " BPM")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(listBPM.map { abs($0 - bpm) > 0.05 } ?? false ? .orange : .primary)
                        .help(listBPM.map { "BPM en este punto. En la lista: \(TagWriter.formatBPM($0))" } ?? "BPM en este punto")
                }
            }
            Text("\(format(player.currentTime))  −\(format(max(0, player.duration - player.currentTime)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var nowPlaying: String {
        guard let url = player.url else { return "Sin pista" }
        if let item = model.visible.first(where: { $0.id == url }), !item.edited.title.isEmpty {
            return item.edited.artist.isEmpty ? item.edited.title : "\(item.edited.artist) – \(item.edited.title)"
        }
        return url.lastPathComponent
    }

    // MARK: Controles

    private func controls(perf: TrackPerformance?) -> some View {
        HStack(spacing: 10) {
            Button { cuePressed(perf) } label: {
                Text("CUE").font(.caption.bold()).frame(width: 40, height: 26)
            }
            .buttonStyle(DeckButtonStyle(stroke: .orange, foreground: .orange, capsule: true))
            .help("Parado: pone el cue principal aquí. Sonando: vuelve al cue principal y para.")
            .disabled(player.url == nil)

            Button { playPressed() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 40, height: 26)
            }
            .buttonStyle(DeckButtonStyle(stroke: .green, foreground: .green, capsule: true))
            .help("Reproducir / pausar (espacio). Sin pista cargada, reproduce la seleccionada.")
            .disabled(player.url == nil && model.selection.isEmpty)

            Divider().frame(height: 20)

            Button { beatJump(-1, perf) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 22) }
                .buttonStyle(DeckButtonStyle(foreground: .primary))
                .help("Un beat atrás")
                .disabled(player.url == nil)
            Button { beatJump(1, perf) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 22) }
                .buttonStyle(DeckButtonStyle(foreground: .primary))
                .help("Un beat adelante")
                .disabled(player.url == nil)

            Divider().frame(height: 20)

            ForEach(0..<8, id: \.self) { i in
                pad(i, cue: perf?.hotCues.first { $0.index == i })
            }

            Spacer()

            Toggle(isOn: $quantize) { Text("Q").font(.caption.bold()) }
                .toggleStyle(.button)
                .help("Cuantizar: los cues caen en el beat más cercano")

            Button { zoomIndex = max(0, zoomIndex - 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Acercar")
                .disabled(zoomIndex == 0)
            Button { zoomIndex = min(Self.zoomLevels.count - 1, zoomIndex + 1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Alejar")
                .disabled(zoomIndex == Self.zoomLevels.count - 1)
        }
        .buttonStyle(.borderless)
    }

    private func pad(_ i: Int, cue: HotCue?) -> some View {
        Button { padPressed(i) } label: {
            Text(Self.letters[i]).font(.caption.bold()).frame(width: 26, height: 22)
        }
        .buttonStyle(DeckButtonStyle(fill: cue?.color.swiftUI ?? Color.gray.opacity(0.18),
                                     foreground: cue == nil ? Color.secondary : .black))
        .help(cue.map { "\($0.label) · \(format($0.seconds)) · tecla \(i + 1) · clic derecho para mover o borrar" }
              ?? "Vacío: clic para poner el cue \(Self.letters[i]) aquí (tecla \(i + 1))")
        .disabled(player.url == nil)
        .contextMenu {
            if let url = player.url {
                Button("Poner aquí") { model.setHotCue(i, at: position(), in: url) }
                if cue != nil {
                    Button("Borrar", role: .destructive) { model.deleteHotCue(i, in: url) }
                }
            }
        }
    }

    // MARK: Acciones

    /// Posición actual, cuantizada si Q está activo.
    private func position() -> Double {
        let t = player.now
        guard quantize, let url = player.url, let perf = model.performance(for: url) else { return t }
        return perf.quantize(t)
    }

    func padPressed(_ i: Int) {
        guard let url = player.url else { return }
        if let cue = model.performance(for: url)?.hotCues.first(where: { $0.index == i }) {
            player.jump(to: cue.seconds)
        } else {
            model.setHotCue(i, at: position(), in: url)
        }
    }

    private func cuePressed(_ perf: TrackPerformance?) {
        guard let url = player.url else { return }
        if player.isPlaying {
            player.pause()
            player.seek(to: perf?.mainCue ?? 0)
        } else {
            let t = position()
            model.setMainCue(at: t, in: url)
            player.seek(to: t)
        }
    }

    private func playPressed() {
        if let url = model.playTarget, url != player.url {
            player.play(url)
        } else {
            player.toggle()
        }
    }

    private func beatJump(_ beats: Int, _ perf: TrackPerformance?) {
        let t = player.now
        guard let perf, let bpm = perf.bpmAt(t) else {
            player.seek(to: t + Double(beats) * 0.5)
            return
        }
        player.seek(to: t + Double(beats) * 60 / bpm)
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d.%d", total / 60, total % 60, Int((s - Double(total)) * 10))
    }
}

/// Botón del deck: fondo/borde dentro del estilo y `contentShape`, así responde en toda su superficie
/// (con `.plain` solo respondía donde hay texto o icono).
struct DeckButtonStyle: ButtonStyle {
    var fill: Color?
    var stroke: Color?
    var foreground: Color
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        DeckButton(configuration: configuration, style: self)
    }

    private struct DeckButton: View {
        let configuration: Configuration
        let style: DeckButtonStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = style.capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 4))
            configuration.label
                .foregroundStyle(style.foreground)
                .background {
                    ZStack {
                        shape.fill(style.fill ?? Color.gray.opacity(style.stroke == nil ? 0.12 : 0.001))
                        if let stroke = style.stroke { shape.stroke(stroke, lineWidth: 2) }
                    }
                }
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
        }
    }
}

extension CueColor {
    var swiftUI: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }
}

extension TrackPerformance {
    /// BPM del tramo del grid que contiene `seconds`.
    /// BPM del tramo del grid que contiene `seconds`. Los puentes de ≤ 4 beats entre dos tramos
    /// (los pone el motor en el break) no cuentan: se muestra el tramo siguiente.
    func bpmAt(_ seconds: Double) -> Double? {
        let s = seconds * sampleRate
        let pairs = Array(zip(grid, grid.dropFirst())).filter { $0.1.beat > $0.0.beat && $0.1.position > $0.0.position }
        guard !pairs.isEmpty else { return nil }
        var i = pairs.firstIndex { $0.1.position >= s } ?? pairs.count - 1
        if i > 0 && i < pairs.count - 1 && pairs[i].1.beat - pairs[i].0.beat <= 4 { i += 1 }
        let (a, b) = pairs[i]
        return 60 * sampleRate * Double(b.beat - a.beat) / (b.position - a.position)
    }
}

// MARK: - Vista general

/// Canción entera con cabezal, cues y cue principal; clic o arrastre para moverse.
struct OverviewStrip: View {
    @Environment(Player.self) private var player
    let waveform: Waveform
    let perf: TrackPerformance?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                WaveformView(waveform: waveform, progress: player.currentTime / max(player.duration, 0.001),
                             perf: perf, duration: player.duration)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    player.scrubbing(true)
                    player.currentTime = max(0, min(1, v.location.x / geo.size.width)) * player.duration
                }
                .onEnded { _ in player.scrubbing(false) })
        }
    }
}

// MARK: - Onda con zoom

/// Onda detallada que se desplaza bajo un cabezal fijo en el centro, con beats, compases y cues.
/// Arrastrar mueve la canción (como girar el plato con el deck parado).
struct ZoomedWaveform: View {
    @Environment(Player.self) private var player
    let detail: DetailWaveform?
    let perf: TrackPerformance?
    let zoom: Double

    @State private var dragStart: Double?

    var body: some View {
        // Leer currentTime aquí hace que, parado, se redibuje al moverse; sonando manda el TimelineView.
        let stoppedTime = player.currentTime
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !player.isPlaying)) { _ in
            let t = player.isPlaying ? player.now : stoppedTime
            Canvas { ctx, size in draw(&ctx, size, t) }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = player.now
                    player.pause()
                    player.scrubbing(true)
                }
                // 1 px = zoom / ancho segundos; arrastrar a la derecha va hacia atrás, como un plato.
                player.currentTime = max(0, min(player.duration, (dragStart ?? 0) - Double(v.translation.width) * zoom / lastWidth))
            }
            .onEnded { _ in
                dragStart = nil
                player.scrubbing(false)
            })
        .overlay {
            GeometryReader { geo in
                Color.clear.onAppear { lastWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in lastWidth = w }
            }
        }
    }

    @State private var lastWidth: Double = 600

    /// Paleta tipo rekordbox: graves rojos, medios verdes, agudos cian, mezclados según la banda que domina
    /// (al cubo, para que gane la dominante y no salga un arcoíris).
    static func bandColor(low: Float, mid: Float, high: Float) -> Color {
        let wl = Double(low * low * low), wm = Double(mid * mid * mid), wh = Double(high * high * high)
        let sum = max(wl + wm + wh, 1e-9)
        return Color(red: (wl * 1.0 + wm * 0.43 + wh * 0.27) / sum,
                     green: (wl * 0.18 + wm * 0.90 + wh * 0.78) / sum,
                     blue: (wl * 0.18 + wm * 0.35 + wh * 1.0) / sum)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height, mid = h / 2
        let pxPerSec = w / zoom
        func x(_ time: Double) -> CGFloat { w / 2 + (time - t) * pxPerSec }
        let from = t - zoom / 2, to = t + zoom / 2

        // Loops.
        for loop in perf?.loops ?? [] where loop.end >= from && loop.start <= to {
            ctx.fill(Path(CGRect(x: x(loop.start), y: 0, width: x(loop.end) - x(loop.start), height: h)),
                     with: .color(loop.color.swiftUI.opacity(0.2)))
        }

        // Onda espejada, coloreada por bandas.
        if let d = detail {
            let cps = d.columnsPerSecond
            let first = max(0, Int(from * cps)), last = min(d.amplitude.count - 1, Int(to * cps) + 1)
            if first <= last {
                let colW = max(1, pxPerSec / cps)
                // Si hay varias columnas por píxel, agrupamos para no dibujar de más.
                let step = max(1, Int(cps / pxPerSec))
                var i = first - first % step
                while i <= last {
                    let j = min(d.amplitude.count, i + step)
                    var a: Float = 0, l: Float = 0, m: Float = 0, hi: Float = 0
                    for k in max(0, i)..<j {
                        a = max(a, d.amplitude[k]); l = max(l, d.low[k]); m = max(m, d.mid[k]); hi = max(hi, d.high[k])
                    }
                    let color = Self.bandColor(low: l, mid: m, high: hi)
                    let barH = CGFloat(a) * (mid - 4)
                    ctx.fill(Path(CGRect(x: x(Double(i) / cps), y: mid - barH, width: colW * CGFloat(step), height: barH * 2)),
                             with: .color(color))
                    i += step
                }
            }
        }

        // Beats (marcas arriba y abajo) y compases (rojo).
        for beat in perf?.beats(from: from, to: to) ?? [] {
            let bx = x(beat.seconds)
            let downbeat = beat.beat % 4 == 0
            let tick: CGFloat = downbeat ? 10 : 6
            let color: Color = downbeat ? .red : .white.opacity(0.7)
            ctx.fill(Path(CGRect(x: bx - 0.5, y: 0, width: 1.5, height: tick)), with: .color(color))
            ctx.fill(Path(CGRect(x: bx - 0.5, y: h - tick, width: 1.5, height: tick)), with: .color(color))
            if downbeat {
                ctx.fill(Path(CGRect(x: bx, y: 0, width: 1, height: h)), with: .color(.white.opacity(0.12)))
            }
        }

        // Cue principal.
        if let main = perf?.mainCue, main >= from, main <= to {
            let cx = x(main)
            ctx.fill(Path(CGRect(x: cx - 0.5, y: 0, width: 1.5, height: h)), with: .color(.orange.opacity(0.8)))
            var tri = Path()
            tri.move(to: CGPoint(x: cx - 7, y: h))
            tri.addLine(to: CGPoint(x: cx + 7, y: h))
            tri.addLine(to: CGPoint(x: cx, y: h - 11))
            ctx.fill(tri, with: .color(.orange))
        }

        // Hot cues.
        for cue in perf?.hotCues ?? [] where cue.seconds >= from - 1 && cue.seconds <= to {
            let cx = x(cue.seconds)
            ctx.fill(Path(CGRect(x: cx - 1, y: 0, width: 2, height: h)), with: .color(cue.color.swiftUI))
            ctx.fill(Path(roundedRect: CGRect(x: cx, y: 0, width: 16, height: 14), cornerRadius: 2), with: .color(cue.color.swiftUI))
            ctx.draw(Text(DeckView.letters[min(cue.index, 7)]).font(.system(size: 10, weight: .bold)).foregroundColor(.black),
                     at: CGPoint(x: cx + 8, y: 7))
        }

        // Cabezal fijo en el centro.
        ctx.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)), with: .color(.white))
    }
}
