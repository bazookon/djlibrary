import Foundation

public struct CueColor: Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct HotCue: Identifiable, Equatable {
    public let index: Int        // 0…7 (A…H en Engine)
    public var label: String
    public var seconds: Double
    public var color: CueColor
    public var id: Int { index }

    public init(index: Int, label: String, seconds: Double, color: CueColor) {
        self.index = index
        self.label = label
        self.seconds = seconds
        self.color = color
    }

    /// Cue nuevo con los valores por defecto de Engine ("Cue N", verde).
    public static func new(index: Int, seconds: Double) -> HotCue {
        HotCue(index: index, label: "Cue \(index + 1)", seconds: seconds, color: CueColor(red: 0x3c, green: 0xeb, blue: 0x50))
    }
}

public struct SavedLoop: Identifiable {
    public let index: Int
    public let label: String
    public let start: Double     // segundos
    public let end: Double
    public let color: CueColor
    public var id: Int { index }
}

/// Cues, loops y grid de una pista de Engine, en segundos.
public struct TrackPerformance {
    public var hotCues: [HotCue] = []
    public var mainCue: Double?
    /// Cue principal que puso el análisis (Engine lo conserva aparte del ajustado).
    public var defaultMainCue: Double?
    public var loops: [SavedLoop] = []
    public var sampleRate: Double = 44100
    public var grid: [BeatMarker] = []
    public var totalSamples: Double = 0

    /// Todos los beats del grid entre `from` y `to` (segundos), con su número de beat.
    public func beats(from: Double, to: Double) -> [(seconds: Double, beat: Int64)] {
        var out: [(Double, Int64)] = []
        for (a, b) in zip(grid, grid.dropFirst()) where b.beat > a.beat {
            let spb = (b.position - a.position) / Double(b.beat - a.beat) / sampleRate
            let aT = a.position / sampleRate, bT = b.position / sampleRate
            guard bT >= from, aT <= to, spb > 0 else { continue }
            var beat = a.beat + Int64(max(0, ((from - aT) / spb).rounded(.down)))
            while beat < b.beat {
                let t = aT + Double(beat - a.beat) * spb
                if t > to { break }
                if t >= from { out.append((t, beat)) }
                beat += 1
            }
        }
        return out
    }

    /// Beat más cercano a `seconds` (para cuantizar); sin grid devuelve el mismo tiempo.
    public func quantize(_ seconds: Double) -> Double {
        let near = beats(from: seconds - 2, to: seconds + 2)
        return near.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }?.seconds ?? seconds
    }

    /// Bloque quickCues de Engine (qCompress) con estos cues.
    public func encodedQuickCues() throws -> Data {
        var w = ByteWriter()
        w.i64be(8)
        for i in 0..<8 {
            if let cue = hotCues.first(where: { $0.index == i }) {
                let label = [UInt8](cue.label.utf8.prefix(255))
                w.u8(UInt8(label.count))
                w.bytes(label)
                w.f64be(cue.seconds * sampleRate)
                w.bytes([0xff, cue.color.red, cue.color.green, cue.color.blue])
            } else {
                w.u8(0)
                w.f64be(-1)
                w.bytes([0, 0, 0, 0])
            }
        }
        let fallback = defaultMainCue ?? mainCue ?? 0
        w.f64be((mainCue ?? fallback) * sampleRate)
        w.u8(mainCue != nil && mainCue != defaultMainCue ? 1 : 0)
        w.f64be(fallback * sampleRate)
        return try BeatData.qCompress(Data(w.data))
    }

    /// Posiciones (segundos) de los downbeats del grid, para pintar compases.
    public func downbeats(until duration: Double) -> [Double] {
        var out: [Double] = []
        for (a, b) in zip(grid, grid.dropFirst()) where b.beat > a.beat {
            let spb = (b.position - a.position) / Double(b.beat - a.beat)
            var beat = a.beat + Int64(((4 - a.beat % 4) % 4))
            while beat < b.beat {
                let t = (a.position + Double(beat - a.beat) * spb) / sampleRate
                if t > duration { return out }
                if t >= 0 { out.append(t) }
                beat += 4
            }
        }
        return out
    }
}

extension EngineDatabase {
    public func performance(trackId: Int64) throws -> TrackPerformance? {
        let rows = try db.query("SELECT trackData, beatData, quickCues, loops FROM PerformanceData WHERE trackId = ?",
                                [.int(trackId)])
        guard let r = rows.first else { return nil }
        var perf = TrackPerformance()
        if let td = r[0].blob, !td.isEmpty, let raw = try? BeatData.qUncompress(td), raw.count >= 8 {
            var reader = ByteReader(raw)
            perf.sampleRate = (try? reader.f64be()) ?? 44100
        }
        if let bd = r[1].blob, !bd.isEmpty, let beats = try? BeatData(blob: bd) {
            if beats.sampleRate > 0 { perf.sampleRate = beats.sampleRate }
            perf.grid = beats.activeGrid
            perf.totalSamples = beats.totalSamples
        }
        let sr = perf.sampleRate
        if let qc = r[2].blob, !qc.isEmpty, let raw = try? BeatData.qUncompress(qc) {
            parseQuickCues(raw, sampleRate: sr, into: &perf)
        }
        if let loops = r[3].blob, !loops.isEmpty {
            parseLoops([UInt8](loops), sampleRate: sr, into: &perf)
        }
        return perf
    }

    /// quickCues (qCompress): count i64 BE; por cue: len u8, etiqueta, posición f64 BE (-1 = vacío), color ARGB;
    /// después cue principal ajustado f64 BE, flag u8, cue principal por defecto f64 BE.
    private func parseQuickCues(_ raw: [UInt8], sampleRate sr: Double, into perf: inout TrackPerformance) {
        var r = ByteReader(raw)
        guard let count = try? r.i64be(), count >= 0, count < 64 else { return }
        for i in 0..<Int(count) {
            guard let len = try? r.u8(), let label = try? r.bytes(Int(len)), let pos = try? r.f64be(),
                  let argb = try? r.bytes(4) else { return }
            if pos >= 0 {
                perf.hotCues.append(HotCue(index: i, label: String(decoding: label, as: UTF8.self), seconds: pos / sr,
                                           color: CueColor(red: argb[1], green: argb[2], blue: argb[3])))
            }
        }
        if let main = try? r.f64be(), main >= 0 { perf.mainCue = main / sr }
        _ = try? r.u8()
        if let dflt = try? r.f64be(), dflt >= 0 { perf.defaultMainCue = dflt / sr }
    }

    /// loops (sin comprimir, little endian): count i64; por loop: len u8, etiqueta, inicio f64, fin f64,
    /// inicio puesto u8, fin puesto u8, color ARGB.
    private func parseLoops(_ raw: [UInt8], sampleRate sr: Double, into perf: inout TrackPerformance) {
        var r = ByteReader(raw)
        guard let count = try? r.i64le(), count >= 0, count < 64 else { return }
        for i in 0..<Int(count) {
            guard let len = try? r.u8(), let label = try? r.bytes(Int(len)), let start = try? r.f64le(),
                  let end = try? r.f64le(), let startSet = try? r.u8(), let endSet = try? r.u8(),
                  let argb = try? r.bytes(4) else { return }
            if startSet != 0, endSet != 0, start >= 0, end > start {
                perf.loops.append(SavedLoop(index: i, label: String(decoding: label, as: UTF8.self),
                                            start: start / sr, end: end / sr,
                                            color: CueColor(red: argb[1], green: argb[2], blue: argb[3])))
            }
        }
    }
}
