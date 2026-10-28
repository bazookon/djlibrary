import Foundation
import zlib

public struct BeatMarker: Equatable {
    public var position: Double   // en samples
    public var beat: Int64
    public var beatsToNext: Int32
    public var unknown: Int32
}

/// Contenido de PerformanceData.beatData de Engine DJ.
///
/// Formato (tras descomprimir con qUncompress: 4 bytes BE de longitud + zlib):
///   sampleRate f64 BE, totalSamples f64 BE, isSet u8,
///   grid por defecto (count i64 BE + markers), grid ajustado (igual), cola de bytes desconocida.
///   Cada marker: posición f64 LE, beat i64 LE, beats hasta el siguiente i32 LE, desconocido i32 LE.
/// El grid "por defecto" es el del análisis (lo usa RESET); el "ajustado" es el que se ve y se usa.
public struct BeatData {
    public var sampleRate: Double
    public var totalSamples: Double
    public var isSet: UInt8
    public var defaultGrid: [BeatMarker]
    public var adjustedGrid: [BeatMarker]
    public var tail: [UInt8]

    public init(blob: Data) throws {
        let raw = try Self.qUncompress(blob)
        var r = ByteReader(raw)
        sampleRate = try r.f64be()
        totalSamples = try r.f64be()
        isSet = try r.u8()
        defaultGrid = try Self.readGrid(&r)
        adjustedGrid = try Self.readGrid(&r)
        tail = r.rest()
    }

    public func encoded() throws -> Data {
        var w = ByteWriter()
        w.f64be(sampleRate)
        w.f64be(totalSamples)
        w.u8(isSet)
        for grid in [defaultGrid, adjustedGrid] {
            w.i64be(Int64(grid.count))
            for m in grid {
                w.f64le(m.position)
                w.i64le(m.beat)
                w.i32le(m.beatsToNext)
                w.i32le(m.unknown)
            }
        }
        w.bytes(tail)
        return try Self.qCompress(Data(w.data))
    }

    /// Grid efectivo (el ajustado si existe).
    public var activeGrid: [BeatMarker] { adjustedGrid.isEmpty ? defaultGrid : adjustedGrid }

    public static func bpm(of grid: [BeatMarker], sampleRate: Double) -> Double? {
        guard let first = grid.first, let last = grid.last, last.position != first.position else { return nil }
        return 60 * sampleRate * Double(last.beat - first.beat) / (last.position - first.position)
    }

    public var bpm: Double? { Self.bpm(of: activeGrid, sampleRate: sampleRate) }

    /// Posición (en samples) del beat 0 según el grid activo; se conserva al cambiar el BPM
    /// para que el downbeat no se mueva.
    public var anchor: Double {
        let grid = activeGrid
        guard let m0 = grid.first else { return 0 }
        guard grid.count > 1 else { return m0.position }
        let m1 = grid[1]
        let spb = (m1.position - m0.position) / Double(m1.beat - m0.beat)
        // Usamos el segmento que contiene el beat 0 si existe.
        for (a, b) in zip(grid, grid.dropFirst()) where a.beat <= 0 && b.beat >= 0 && b.beat != a.beat {
            let s = (b.position - a.position) / Double(b.beat - a.beat)
            return a.position - Double(a.beat) * s
        }
        return m0.position - Double(m0.beat) * spb
    }

    /// Reemplaza el grid ajustado por uno constante al BPM dado, manteniendo el beat 0.
    /// El grid por defecto (análisis) no se toca, así RESET en Engine sigue funcionando.
    public mutating func setConstantBPM(_ bpm: Double) {
        let anchor = self.anchor
        let lastUnknown = activeGrid.last?.unknown ?? 0
        let spb = 60 * sampleRate / bpm
        let beats = max(1, Int64(((totalSamples - anchor) / spb).rounded(.up)))
        adjustedGrid = [
            BeatMarker(position: anchor - 4 * spb, beat: -4, beatsToNext: Int32(beats + 4), unknown: 0),
            BeatMarker(position: anchor + Double(beats) * spb, beat: beats, beatsToNext: 0, unknown: lastUnknown),
        ]
        isSet = 1
    }

    /// Grid de Engine a partir de los tramos detectados (uno por cambio de tempo).
    ///
    /// Cada tramo mantiene su tempo exacto. Entre el último beat de un tramo y el primero del siguiente va un
    /// "puente" de 1–4 beats (suele caer en el break) elegido para que el primer "1" del tramo nuevo sea un
    /// downbeat (número de beat múltiplo de 4, como los compases de Engine).
    public static func markers(for segments: [TempoSegment], sampleRate sr: Double, totalSamples: Double) -> [BeatMarker] {
        guard let first = segments.first else { return [] }
        var markers: [BeatMarker] = []
        // Numeramos para que el downbeat del primer tramo sea el beat 0.
        var spb = 60 / first.bpm * sr
        var beat = Int64(-first.downbeatOffset - 4)
        var pos = first.firstBeat * sr - 4 * spb
        markers.append(BeatMarker(position: pos, beat: beat, beatsToNext: 0, unknown: 0))

        for next in segments.dropFirst() {
            let nextFirst = next.firstBeat * sr
            // Último beat del tramo actual antes del primer beat del siguiente.
            let kMax = Int64(((nextFirst - pos) / spb - 0.25).rounded(.down))
            guard kMax > 0 else { continue }
            let nextSpb = 60 / next.bpm * sr
            // Elegimos dónde acaba el tramo (hasta 7 beats antes) y cuántos beats lleva el puente para que
            // el downbeat del tramo nuevo sea múltiplo de 4 con beats de tamaño lo más normal posible.
            var best: (k: Int64, n: Int64, error: Double)?
            for j in 0...7 {
                let k = kMax - Int64(j)
                guard k > 0 else { break }
                let gap = nextFirst - (pos + Double(k) * spb)
                let natural = max(1, Int64((gap / nextSpb).rounded()))
                for n in max(1, natural - 2)...(natural + 3) where (beat + k + n + Int64(next.downbeatOffset)) % 4 == 0 {
                    let error = abs(gap / Double(n) / nextSpb - 1)
                    if best == nil || error < best!.error { best = (k, n, error) }
                }
            }
            guard let choice = best else { continue }
            beat += choice.k
            pos += Double(choice.k) * spb
            markers.append(BeatMarker(position: pos, beat: beat, beatsToNext: 0, unknown: 0))
            beat += choice.n
            pos = nextFirst
            spb = nextSpb
            markers.append(BeatMarker(position: pos, beat: beat, beatsToNext: 0, unknown: 0))
        }
        // Último marcador pasado el final del audio.
        let remaining = max(1, Int64(((totalSamples - pos) / spb).rounded(.up)))
        markers.append(BeatMarker(position: pos + Double(remaining) * spb, beat: beat + remaining, beatsToNext: 0, unknown: 1))
        for i in 0..<(markers.count - 1) {
            markers[i].beatsToNext = Int32(markers[i + 1].beat - markers[i].beat)
        }
        return markers
    }

    /// Sustituye el grid ajustado por el de los tramos detectados.
    public mutating func setSegments(_ segments: [TempoSegment]) {
        let grid = Self.markers(for: segments, sampleRate: sampleRate, totalSamples: totalSamples)
        guard grid.count >= 2 else { return }
        adjustedGrid = grid
        isSet = 1
    }

    private static func readGrid(_ r: inout ByteReader) throws -> [BeatMarker] {
        let count = try r.i64be()
        guard count >= 0 && count < 100_000 else { throw BeatDataError.corrupt }
        var grid: [BeatMarker] = []
        for _ in 0..<count {
            grid.append(BeatMarker(position: try r.f64le(), beat: try r.i64le(),
                                   beatsToNext: try r.i32le(), unknown: try r.i32le()))
        }
        return grid
    }

    static func qUncompress(_ blob: Data) throws -> [UInt8] {
        let bytes = [UInt8](blob)
        guard bytes.count > 4 else { throw BeatDataError.corrupt }
        var expected = uLongf(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        var out = [UInt8](repeating: 0, count: Int(expected))
        let rc = bytes.withUnsafeBufferPointer { src in
            uncompress(&out, &expected, src.baseAddress! + 4, uLong(bytes.count - 4))
        }
        guard rc == Z_OK else { throw BeatDataError.corrupt }
        return Array(out.prefix(Int(expected)))
    }

    static func qCompress(_ data: Data) throws -> Data {
        let src = [UInt8](data)
        var destLen = compressBound(uLong(src.count))
        var out = [UInt8](repeating: 0, count: Int(destLen))
        let rc = compress2(&out, &destLen, src, uLong(src.count), Z_DEFAULT_COMPRESSION)
        guard rc == Z_OK else { throw BeatDataError.corrupt }
        let n = UInt32(src.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + out.prefix(Int(destLen)))
    }
}

public enum BeatDataError: LocalizedError {
    case corrupt
    public var errorDescription: String? { "beatData de Engine con formato inesperado" }
}
