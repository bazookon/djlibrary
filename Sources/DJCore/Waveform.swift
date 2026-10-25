import Foundation

/// Forma de onda de vista general de Engine (PerformanceData.overviewWaveFormData).
///
/// Formato tras qUncompress: count i64 BE, count i64 BE, samplesPorColumna f64 BE,
/// luego `count` columnas de 3 bytes (graves, medios, agudos) y una última con el máximo de cada banda (no se usa).
public struct Waveform {
    public struct Column {
        public let low: Double   // 0…1, normalizado al pico de la pista
        public let mid: Double
        public let high: Double
        public var amplitude: Double { max(low, mid, high) }
    }

    public let columns: [Column]

    public init(blob: Data) throws {
        let raw = try BeatData.qUncompress(blob)
        var r = ByteReader(raw)
        let count = Int(try r.i64be())
        _ = try r.i64be()
        _ = try r.f64be()
        guard count > 0, count < 100_000, raw.count >= 24 + (count + 1) * 3 else { throw BeatDataError.corrupt }
        let base = 24
        // Un único máximo para las tres bandas: así la proporción entre bandas (el color) es la real,
        // que es lo que da los naranjas/amarillos de Engine. Normalizar por banda lo deja todo pálido.
        let values = raw[base..<base + count * 3]
        let peak = Double(max(1, values.max() ?? 1))
        columns = (0..<count).map { i in
            let o = base + i * 3
            return Column(low: Double(raw[o]) / peak, mid: Double(raw[o + 1]) / peak, high: Double(raw[o + 2]) / peak)
        }
    }
}

extension EngineDatabase {
    public func waveform(trackId: Int64) throws -> Waveform? {
        let rows = try db.query("SELECT overviewWaveFormData FROM PerformanceData WHERE trackId = ?", [.int(trackId)])
        guard let blob = rows.first?.first?.blob, !blob.isEmpty else { return nil }
        return try Waveform(blob: blob)
    }
}
