import Accelerate
import AVFoundation
import Foundation

/// Tramo de tempo constante detectado.
public struct TempoSegment: Equatable {
    public var start: Double        // segundos (inicio del tramo)
    public var bpm: Double          // entero salvo que se pida precisión decimal
    public var firstBeat: Double    // primer beat del tramo (segundos)
    public var downbeatOffset: Int  // cuántos beats tras `firstBeat` cae el primer "1" del compás (0…3)
}

public struct TempoAnalysis {
    public var segments: [TempoSegment]
    public var duration: Double
    /// BPM del tramo más largo (el que se ve en la lista).
    public var mainBPM: Double {
        var best = segments.first?.bpm ?? 0, bestLen = -1.0
        for (i, s) in segments.enumerated() {
            let end = i + 1 < segments.count ? segments[i + 1].start : duration
            if end - s.start > bestLen { bestLen = end - s.start; best = s.bpm }
        }
        return best
    }
}

/// Detector de BPM pensado para música de DJ:
/// - BPM enteros (los edits y remixes casi siempre lo son),
/// - cambios de tempo en transiciones (p. ej. 128 → 98) con un camino de Viterbi que penaliza cambiar,
/// - octava elegida con un rango y comparando la fuerza de los contratiempos.
public enum TempoDetector {
    public static var minBPM = 70.0
    public static var maxBPM = 165.0
    /// Tempos hasta aquí se revisan como posible ½ o ⅔ del real.
    public static var slowLimit = 80.0

    // MARK: Curva de ataques

    struct Onsets {
        let fps: Double
        /// Segundos a sumar al instante de cada frame: el golpe se detecta hacia el centro de la ventana del FFT.
        var latency: Double = 0
        let flux: [Float]   // flujo espectral (todas las bandas), con la media local restada
        let low: [Float]    // flujo de graves (< ~130 Hz), para el bombo / compás
    }

    static func onsets(url: URL) throws -> (Onsets, Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        // Diezmamos ×2 (promedio de pares): para ataques sobra con ~22 kHz y va el doble de rápido.
        let decim = format.sampleRate > 30000 ? 2 : 1
        let sr = format.sampleRate / Double(decim)
        let n = 1024, hop = 128
        let fps = sr / Double(hop)
        let duration = Double(file.length) / format.sampleRate

        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length) / decim + 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw TagError.malformed("audio") }
        var acc: Float = 0, k = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var x: Float = 0
                for c in 0..<channels { x += data[c][i] }
                acc += x / Float(channels)
                k += 1
                if k == decim { mono.append(acc / Float(decim)); acc = 0; k = 0 }
            }
        }

        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw TagError.malformed("fft") }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let frames = max(0, (mono.count - n) / hop)
        var flux = [Float](repeating: 0, count: frames), low = [Float](repeating: 0, count: frames)
        var prev = [Float](repeating: 0, count: n / 2)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2)
        let lowBins = max(1, Int((130.0 / sr) * Double(n)))
        let topBin = min(n / 2, Int((9000.0 / sr) * Double(n)))

        for f in 0..<frames {
            mono.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
                }
            }
            var sum: Float = 0, lsum: Float = 0
            for b in 1..<topBin {
                let v = log1pf(mag[b] * 10)
                let d = v - prev[b]
                if d > 0 {
                    sum += d
                    if b <= lowBins { lsum += d }
                }
                prev[b] = v
            }
            flux[f] = sum
            low[f] = lsum
        }
        return (Onsets(fps: fps, latency: Double(n / 2) / sr + 0.009, flux: detrended(flux, radius: Int(fps * 0.25)),
                       low: detrended(low, radius: Int(fps * 0.25))), duration)
    }

    /// Suma ponderada de dos curvas, cada una normalizada a su percentil 99.
    static func mix(_ a: [Float], weight wa: Float, _ b: [Float], weight wb: Float) -> [Float] {
        func scale(_ v: [Float]) -> Float {
            let sorted = v.sorted()
            return max(sorted.isEmpty ? 1 : sorted[Int(Double(sorted.count - 1) * 0.99)], 1e-6)
        }
        let sa = wa / scale(a), sb = wb / scale(b)
        return zip(a, b).map { $0 * sa + $1 * sb }
    }

    /// Resta la media móvil y deja solo lo positivo: quedan los picos (ataques).
    static func detrended(_ v: [Float], radius: Int) -> [Float] {
        guard v.count > 2 * radius + 1, radius > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var sum = v[0...(2 * radius)].reduce(0, +)
        for i in 0..<v.count {
            let lo = max(0, i - radius), hi = min(v.count - 1, i + radius)
            if i > radius && i + radius < v.count { sum += v[i + radius] - v[i - radius - 1] }
            let mean = (i > radius && i + radius < v.count) ? sum / Float(2 * radius + 1)
                : v[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            out[i] = max(0, v[i] - mean)
        }
        return out
    }

    // MARK: Peine de tempo

    /// Fuerza media de los ataques en una rejilla de beats (periodo `period` en frames) dentro de [from, to),
    /// con la mejor fase. Tolera ±1 frame por beat. Devuelve (puntuación, fase en frames).
    static func comb(_ env: [Float], from: Int, to: Int, period: Double) -> (score: Float, phase: Double) {
        guard period > 2, to - from > Int(period * 2) else { return (0, 0) }
        var best: Float = -1, bestPhase = 0.0
        let phases = Int(period.rounded(.up))
        for p in 0..<phases {
            var s: Float = 0, count = 0
            var t = Double(from + p)
            while t < Double(to) {
                let i = Int(t.rounded())
                if i > 0 && i + 1 < env.count {
                    s += max(env[i], max(env[i - 1], env[i + 1]) * 0.8)
                    count += 1
                }
                t += period
            }
            if count > 0 {
                let m = s / Float(count)
                if m > best { best = m; bestPhase = Double(from + p) }
            }
        }
        return (best, bestPhase)
    }

    // MARK: Detección

    public struct Options {
        public var windowSeconds = 8.0
        public var hopSeconds = 1.0
        /// Coste de cambiar de tempo entre ventanas (en unidades de puntuación normalizada).
        public var switchPenalty = 4.0
        /// Tramos más cortos que esto se funden con el vecino.
        public var minSegmentSeconds = 20.0
        /// Primer y último tramo: los intros/outros de DJ son cortos (16 compases a 128 = 30 s, 8 = 15 s).
        public var minEdgeSegmentSeconds = 8.0
        /// Por debajo de este pico/media una ventana no tiene pulso claro (break, acapella) y no vota.
        public var minPeakRatio: Float = 1.6
        /// Un tramo intermedio de menos de 60 s con menos confianza media que esto se reparte a los vecinos.
        public var minSegmentConfidence: Float = 0.45
        /// Si los contratiempos tienen al menos esta fuerza relativa, se elige la octava rápida.
        public var doubleRatio: Float = 0.82
        /// Peso de los graves frente al flujo completo en la curva de tempo.
        public var lowWeight: Float = 2
        public init() {}
    }

    /// Para depurar: mejor BPM y confianza de cada ventana.
    public static func windows(url: URL, options o: Options = Options()) throws -> [(time: Double, bpm: Int, second: Int, confidence: Float)] {
        let (on, _) = try onsets(url: url)
        let fps = on.fps
        let env = mix(on.low, weight: o.lowWeight, on.flux, weight: 1)
        let bpms = Array(Int(minBPM)...Int(maxBPM))
        let win = Int(o.windowSeconds * fps), hop = Int(o.hopSeconds * fps)
        var out: [(Double, Int, Int, Float)] = []
        var st = 0
        while st + win <= env.count {
            let row = bpms.map { comb(env, from: st, to: st + win, period: fps * 60 / Double($0)).score }
            let order = row.indices.sorted { row[$0] > row[$1] }
            let mean = row.reduce(0, +) / Float(row.count)
            let second = order.dropFirst().first { abs(bpms[$0] - bpms[order[0]]) > 2 } ?? order[0]
            out.append((Double(st + win / 2) / fps, bpms[order[0]], bpms[second], row[order[0]] / max(mean, 1e-6)))
            st += hop * 2
        }
        return out
    }

    public static func analyze(url: URL, options: Options = Options()) throws -> TempoAnalysis {
        let (on, duration) = try onsets(url: url)
        return analyze(onsets: on, duration: duration, options: options)
    }

    static func analyze(onsets on: Onsets, duration: Double, options o: Options) -> TempoAnalysis {
        // El bombo marca el beat; la percusión media (tresillos del dembow) engaña con 2:3. Mezclamos con más peso a graves.
        let fps = on.fps
        let env = mix(on.low, weight: o.lowWeight, on.flux, weight: 1)
        let bpms = Array(Int(minBPM)...Int(maxBPM))
        let win = Int(o.windowSeconds * fps), hop = Int(o.hopSeconds * fps)
        guard env.count > win else { return TempoAnalysis(segments: [], duration: duration) }

        // Puntuación de cada BPM entero en cada ventana (normalizada al máximo de la ventana).
        var starts: [Int] = []
        var s = 0
        while s + win <= env.count { starts.append(s); s += hop }
        var scores = [[Float]](repeating: [], count: starts.count)
        var confidence = [Float](repeating: 0, count: starts.count)
        for (w, st) in starts.enumerated() {
            var row = [Float](repeating: 0, count: bpms.count)
            for (j, b) in bpms.enumerated() {
                row[j] = comb(env, from: st, to: st + win, period: fps * 60 / Double(b)).score
            }
            let mx = row.max() ?? 0
            let mean = row.reduce(0, +) / Float(row.count)
            // Ventanas sin pulso claro (breaks, acapellas) no deciden: confianza baja → emisión plana.
            confidence[w] = mx > 0 ? min(1, max(0, (mx / max(mean, 1e-6) - o.minPeakRatio) / 0.8)) : 0
            scores[w] = mx > 0 ? row.map { $0 / mx } : row
        }

        // Viterbi: estado = BPM entero; coste = (1 - puntuación)·confianza + penalización por cambiar.
        let nS = bpms.count
        var cost = [Float](repeating: 0, count: nS)
        var back = [[Int]](repeating: [Int](repeating: 0, count: nS), count: starts.count)
        for w in 0..<starts.count {
            var next = [Float](repeating: 0, count: nS)
            let bestPrev = w == 0 ? 0 : cost.indices.min { cost[$0] < cost[$1] }!
            for j in 0..<nS {
                let emit = (1 - scores[w][j]) * confidence[w] * 10
                if w == 0 { next[j] = emit; continue }
                let stay = cost[j]
                let jump = cost[bestPrev] + Float(o.switchPenalty)
                if stay <= jump { next[j] = stay + emit; back[w][j] = j } else { next[j] = jump + emit; back[w][j] = bestPrev }
            }
            cost = next
        }
        var path = [Int](repeating: 0, count: starts.count)
        path[starts.count - 1] = cost.indices.min { cost[$0] < cost[$1] }!
        for w in stride(from: starts.count - 1, to: 0, by: -1) { path[w - 1] = back[w][path[w]] }

        // Tramos a partir del camino (el cambio se sitúa en el centro de la ventana donde ocurre).
        var raw: [(start: Double, bpm: Int)] = []
        for (w, j) in path.enumerated() where raw.last?.bpm != bpms[j] {
            let center = (Double(starts[w]) + Double(win) / 2) / fps
            raw.append((w == 0 ? 0 : center, bpms[j]))
        }
        let windowConfidence = starts.indices.map { ((Double(starts[$0]) + Double(win) / 2) / fps, confidence[$0]) }
        let merged = cleanSegments(raw, env: env, fps: fps, duration: duration, confidence: windowConfidence, options: o)

        // Octava y fase de cada tramo con todo su audio.
        var segments: [TempoSegment] = []
        for (i, seg) in merged.enumerated() {
            let a = Int(seg.start * fps), b = i + 1 < merged.count ? Int(merged[i + 1].start * fps) : env.count
            let bpm = chooseOctave(Double(seg.bpm), env: env, from: a, to: b, fps: fps, ratio: o.doubleRatio)
            let period = fps * 60 / bpm
            var phase = comb(env, from: a, to: b, period: period).phase
            // El primer beat es el más temprano de la rejilla desde el inicio del tramo; un golpe justo en 0 s
            // cae "antes" del frame 0 por la latencia del FFT, así que dejamos que la fase sea negativa.
            let earliest = Double(a) - on.latency * fps - 2
            while phase - period >= earliest { phase -= period }
            let downbeat = downbeatOffset(env, firstBeat: phase, period: period, to: b)
            segments.append(TempoSegment(start: seg.start, bpm: bpm, firstBeat: phase / fps + on.latency, downbeatOffset: downbeat))
        }
        // Tramos contiguos que tras la octava quedaron iguales.
        var k = 1
        while k < segments.count {
            if segments[k].bpm == segments[k - 1].bpm { segments.remove(at: k) } else { k += 1 }
        }
        return TempoAnalysis(segments: segments, duration: duration)
    }

    /// Limpia el camino de Viterbi:
    /// 1. un tramo cuyo tempo es 2×, ½, 3:2, 2:3, 4:3 o 3:4 de un vecino es la misma música mal leída
    ///    (tresillos, medio tiempo): toma el tempo del vecino que más dura;
    /// 2. los tramos cortos (zona de transición, rampas, breaks) se reparten al vecino que mejor encaja.
    static func cleanSegments(_ raw: [(start: Double, bpm: Int)], env: [Float], fps: Double, duration: Double,
                              confidence: [(time: Double, value: Float)] = [],
                              options o: Options) -> [(start: Double, bpm: Int)] {
        var segs = raw
        func end(_ i: Int) -> Double { i + 1 < segs.count ? segs[i + 1].start : duration }
        func length(_ i: Int) -> Double { end(i) - segs[i].start }
        func related(_ a: Int, _ b: Int) -> Bool {
            let r = Double(a) / Double(b)
            return [2, 0.5, 1.5, 2.0 / 3].contains { abs(r / $0 - 1) < 0.015 }
        }
        func fuseEqual() {
            var j = 1
            while j < segs.count {
                if abs(segs[j].bpm - segs[j - 1].bpm) <= 1 {
                    // Nos quedamos con el tempo del más largo de los dos.
                    if length(j) > length(j - 1) { segs[j - 1].bpm = segs[j].bpm }
                    segs.remove(at: j)
                } else { j += 1 }
            }
        }
        // Tempo total por BPM (para decidir quién manda).
        func totalTime(_ bpm: Int) -> Double { segs.indices.filter { segs[$0].bpm == bpm }.map(length).reduce(0, +) }

        var changed = true
        while changed && segs.count > 1 {
            changed = false
            fuseEqual()
            // 1. Tempos emparentados con un vecino, solo en tramos intermedios cortos:
            //    100→150 o 126→84 al principio/final son transiciones reales.
            for i in segs.indices where i > 0 && i < segs.count - 1 && length(i) < o.minSegmentSeconds * 1.5 {
                let neighbors = [i - 1, i + 1].filter { $0 >= 0 && $0 < segs.count }
                if let n = neighbors.filter({ related(segs[i].bpm, segs[$0].bpm) })
                    .max(by: { totalTime(segs[$0].bpm) < totalTime(segs[$1].bpm) }),
                   totalTime(segs[n].bpm) >= totalTime(segs[i].bpm) {
                    segs[i].bpm = segs[n].bpm
                    changed = true
                    break
                }
            }
            if changed { continue }
            // 2. El tramo más corto, si no llega al mínimo, se lo queda el vecino que mejor puntúa en él.
            func minimum(_ i: Int) -> Double { i == 0 || i == segs.count - 1 ? o.minEdgeSegmentSeconds : o.minSegmentSeconds }
            // Confianza media de las ventanas del tramo: los breaks con medio tiempo dan tramos de poca convicción.
            func meanConfidence(_ i: Int) -> Float {
                let inside = confidence.filter { $0.time >= segs[i].start && $0.time < end(i) }.map(\.value)
                return inside.isEmpty ? 1 : inside.reduce(0, +) / Float(inside.count)
            }
            let weak = segs.indices.filter { i in
                let interiorShort = i > 0 && i < segs.count - 1 && length(i) < 60
                return length(i) < minimum(i)
                    || (interiorShort && meanConfidence(i) < o.minSegmentConfidence)
                    // Un tramo lento en medio de dos rápidos es un break a medio tiempo.
                    || (interiorShort && Double(segs[i].bpm) <= slowLimit
                        && segs[i - 1].bpm > segs[i].bpm && segs[i + 1].bpm > segs[i].bpm)
            }
            if let i = weak.min(by: { length($0) < length($1) }) {
                let a = Int(segs[i].start * fps), b = Int(end(i) * fps)
                let options = [i - 1, i + 1].filter { $0 >= 0 && $0 < segs.count }
                let best = options.max { x, y in
                    comb(env, from: a, to: b, period: fps * 60 / Double(segs[x].bpm)).score
                        < comb(env, from: a, to: b, period: fps * 60 / Double(segs[y].bpm)).score
                }
                if let best { segs[i].bpm = segs[best].bpm; changed = true }
            }
        }
        fuseEqual()
        if !segs.isEmpty { segs[0].start = 0 }
        return segs
    }

    /// Entre b/2, b y 2b (dentro del rango), sube de octava si los contratiempos son casi tan fuertes como los beats.
    static func chooseOctave(_ bpm: Double, env: [Float], from: Int, to: Int, fps: Double, ratio: Float) -> Double {
        var b = bpm
        while b / 2 >= minBPM && comb(env, from: from, to: to, period: fps * 60 / (b / 2)).score >= comb(env, from: from, to: to, period: fps * 60 / b).score / ratio {
            b /= 2
        }
        while b * 2 <= maxBPM {
            let slow = comb(env, from: from, to: to, period: fps * 60 / b).score
            let fast = comb(env, from: from, to: to, period: fps * 60 / (b * 2)).score
            if fast >= slow * ratio { b *= 2 } else { break }
        }
        // ≤ 80 BPM casi nunca es real en música de DJ: suele ser ½ (142 → 71) o ⅔ (105 → 70, 120 → 80) del tempo.
        if b <= slowLimit {
            let base = comb(env, from: from, to: to, period: fps * 60 / b).score
            let options = [b * 2, b * 1.5].filter { $0 <= maxBPM }
                .map { (bpm: $0, score: comb(env, from: from, to: to, period: fps * 60 / $0).score) }
            if let best = options.max(by: { $0.score < $1.score }), best.score >= base * 0.6 { b = best.bpm.rounded() }
        }
        return b
    }

    /// Posición del compás: el primer golpe fuerte del tramo es el "1" (los edits de DJ arrancan en el 1,
    /// también tras una transición). En el dembow el bombo suena igual en los 4 tiempos y no sirve para distinguir.
    static func downbeatOffset(_ env: [Float], firstBeat: Double, period: Double, to: Int) -> Int {
        var strengths: [Float] = []
        var t = firstBeat
        while t < Double(to) {
            let f = min(max(Int(t.rounded()), 1), env.count - 2)
            strengths.append(env.count > 2 ? max(env[f], max(env[f - 1], env[f + 1])) : 0)
            t += period
        }
        let sorted = strengths.sorted()
        guard !sorted.isEmpty else { return 0 }
        let median = sorted[sorted.count / 2]
        let first = strengths.firstIndex { $0 >= median * 0.5 } ?? 0
        return first % 4
    }
}
