import AVFoundation
import Foundation

/// Onda detallada para la vista con zoom, calculada del audio (Engine solo guarda la vista general).
/// Cada columna tiene la energía (RMS) de la señal completa (altura) y la de graves/medios/agudos (color).
/// Con RMS en vez de pico se ve el ataque y la caída de cada golpe; en masters comprimidos el pico está siempre arriba.
public struct DetailWaveform {
    public let columnsPerSecond: Double
    public let amplitude: [Float]   // 0…1, RMS de la señal completa
    public let low: [Float]         // 0…1, cada banda normalizada a su propio pico
    public let mid: [Float]
    public let high: [Float]

    public var duration: Double { Double(amplitude.count) / columnsPerSecond }

    /// Vista general (para pistas sin onda de Engine): picos por tramo, color por bandas.
    public func overview(columns count: Int = 1024) -> Waveform {
        guard !amplitude.isEmpty else { return Waveform(columns: []) }
        return Waveform(columns: (0..<count).map { i in
            let lo = i * amplitude.count / count, hi = max(lo + 1, (i + 1) * amplitude.count / count)
            let a = Double(amplitude[lo..<min(hi, amplitude.count)].max() ?? 0)
            let l = Double(low[lo..<min(hi, low.count)].max() ?? 0)
            let m = Double(mid[lo..<min(hi, mid.count)].max() ?? 0)
            let h = Double(high[lo..<min(hi, high.count)].max() ?? 0)
            let peak = max(l, m, h, 1e-6)
            return Waveform.Column(low: l / peak * a, mid: m / peak * a, high: h / peak * a)
        })
    }

    public static func compute(url: URL, columnsPerSecond: Double = 150) throws -> DetailWaveform {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        let hop = max(1, Int((sr / columnsPerSecond).rounded()))

        // Graves < 200 Hz, medios 200–2500 Hz, agudos > 2500 Hz.
        var lowLP = Biquad.lowPass(200, sr), midHP = Biquad.highPass(200, sr), midLP = Biquad.lowPass(2500, sr)
        var highHP = Biquad.highPass(2500, sr)

        var amp: [Float] = [], low: [Float] = [], mid: [Float] = [], high: [Float] = []
        let capacity = Int(file.length) / hop + 1
        amp.reserveCapacity(capacity); low.reserveCapacity(capacity); mid.reserveCapacity(capacity); high.reserveCapacity(capacity)

        var pA: Float = 0, pL: Float = 0, pM: Float = 0, pH: Float = 0, n = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw TagError.malformed("audio") }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<frames {
                var x: Float = 0
                for c in 0..<channels { x += data[c][i] }
                x /= Float(channels)
                let l = lowLP.process(x), m = midLP.process(midHP.process(x)), h = highHP.process(x)
                pA += x * x; pL += l * l; pM += m * m; pH += h * h
                n += 1
                if n == hop {
                    let k = Float(hop)
                    amp.append((pA / k).squareRoot()); low.append((pL / k).squareRoot())
                    mid.append((pM / k).squareRoot()); high.append((pH / k).squareRoot())
                    pA = 0; pL = 0; pM = 0; pH = 0; n = 0
                }
            }
        }
        if n > 0 {
            let k = Float(n)
            amp.append((pA / k).squareRoot()); low.append((pL / k).squareRoot())
            mid.append((pM / k).squareRoot()); high.append((pH / k).squareRoot())
        }

        return DetailWaveform(columnsPerSecond: sr / Double(hop),
                              amplitude: normalized(amp), low: smoothed(normalized(low)), mid: smoothed(normalized(mid)),
                              high: smoothed(normalized(high)))
    }

    /// Media móvil de 5 columnas (~33 ms): el color no parpadea dentro de un mismo golpe.
    static func smoothed(_ v: [Float], radius: Int = 2) -> [Float] {
        guard v.count > 2 * radius else { return v }
        var out = v
        var sum = v[0...(2 * radius)].reduce(0, +)
        for i in radius..<(v.count - radius) {
            out[i] = sum / Float(2 * radius + 1)
            if i + radius + 1 < v.count { sum += v[i + radius + 1] - v[i - radius] }
        }
        return out
    }

    /// Normaliza al percentil 99,5 para que un pico suelto no aplaste el resto.
    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let sorted = v.sorted()
        let ref = max(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))], 1e-6)
        return v.map { min(1, $0 / ref) }
    }
}

/// Filtro biquad (RBJ cookbook), forma directa I.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }

    static func lowPass(_ f: Double, _ sr: Double) -> Biquad { make(f, sr, high: false) }
    static func highPass(_ f: Double, _ sr: Double) -> Biquad { make(f, sr, high: true) }

    private static func make(_ f: Double, _ sr: Double, high: Bool) -> Biquad {
        let w = 2 * Double.pi * f / sr, alpha = sin(w) / (2 * 0.7071), c = cos(w)
        let a0 = 1 + alpha
        let b0 = high ? (1 + c) / 2 : (1 - c) / 2
        let b1 = high ? -(1 + c) : 1 - c
        return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b0 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }
}
