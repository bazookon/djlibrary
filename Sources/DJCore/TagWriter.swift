import AVFoundation
import Foundation

public struct TagEdits {
    public var title: String?
    public var artist: String?
    public var clearAlbum = false
    /// "" quita el género.
    public var genre: String?
    public var bpm: Double?
    public var artwork: ArtworkEdit?

    public init() {}
}

public enum ArtworkEdit {
    case remove
    case jpeg(Data)
}

public struct FileTags {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var bpm: Double?
}

public enum TagError: LocalizedError {
    case unsupported(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Formato .\(ext) no soportado para escribir tags"
        case .malformed(let what): return "Archivo con estructura inesperada (\(what))"
        }
    }
}

/// Lee y escribe tags (ID3v2 en MP3/WAV/AIFF, átomos iTunes en M4A).
public enum TagWriter {
    enum Container { case mp3, wav, aiff, m4a }

    static func container(_ url: URL) throws -> Container {
        switch url.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "wav", "wave": return .wav
        case "aif", "aiff": return .aiff
        case "m4a", "mp4", "aac": return .m4a
        case let ext: throw TagError.unsupported(ext)
        }
    }

    // MARK: Lectura

    public static func read(_ url: URL) async throws -> FileTags {
        if try container(url) == .m4a { return try await readM4A(url) }
        let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        let tag: ID3Tag?
        switch try container(url) {
        case .mp3: tag = ID3Tag(bytes: bytes)
        case .wav: tag = riffChunks(bytes, bigEndian: false).first { $0.isID3 }.flatMap { ID3Tag(bytes: Array(bytes[$0.body])) }
        case .aiff: tag = riffChunks(bytes, bigEndian: true).first { $0.isID3 }.flatMap { ID3Tag(bytes: Array(bytes[$0.body])) }
        case .m4a: tag = nil
        }
        guard let tag else { return FileTags() }
        return FileTags(title: tag.text("TIT2"), artist: tag.text("TPE1"), album: tag.text("TALB"), genre: tag.text("TCON"),
                        bpm: tag.text("TBPM").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) })
    }

    // MARK: Escritura

    /// Escribe los tags en el archivo. Devuelve el nuevo tamaño en bytes.
    @discardableResult
    public static func write(_ url: URL, _ edits: TagEdits) async throws -> Int64 {
        let output: Data
        switch try container(url) {
        case .m4a:
            output = try await writeM4A(url, edits)
        case let c:
            let bytes = [UInt8](try Data(contentsOf: url))
            switch c {
            case .mp3: output = Data(rewriteMP3(bytes, edits))
            case .wav: output = Data(try rewriteChunked(bytes, edits, bigEndian: false))
            default: output = Data(try rewriteChunked(bytes, edits, bigEndian: true))
            }
        }
        try overwriteInPlace(url, with: output)
        return Int64(output.count)
    }

    static func apply(_ edits: TagEdits, to tag: inout ID3Tag) {
        if let t = edits.title { tag.setText("TIT2", t) }
        if let a = edits.artist { tag.setText("TPE1", a) }
        if edits.clearAlbum { tag.remove("TALB") }
        if let g = edits.genre {
            if g.isEmpty { tag.remove("TCON") } else { tag.setText("TCON", g) }
        }
        if let bpm = edits.bpm { tag.setText("TBPM", formatBPM(bpm)) }
        switch edits.artwork {
        case .remove: tag.remove("APIC")
        case .jpeg(let data): tag.setPicture([UInt8](data), mime: "image/jpeg")
        case nil: break
        }
    }

    public static func formatBPM(_ bpm: Double) -> String {
        abs(bpm - bpm.rounded()) < 0.005 ? String(Int(bpm.rounded())) : String(format: "%.2f", bpm)
    }

    static func rewriteMP3(_ bytes: [UInt8], _ edits: TagEdits) -> [UInt8] {
        var tag = ID3Tag(bytes: bytes) ?? ID3Tag()
        apply(edits, to: &tag)
        var audio = bytes[ID3Tag.length(in: bytes)...]
        // ID3v1 al final: lo quitamos para que no contradiga al v2.
        if audio.count >= 128, Array(audio.suffix(128).prefix(3)) == [0x54, 0x41, 0x47] { audio = audio.dropLast(128) }
        return tag.serialized(padding: 1024) + audio
    }

    struct Chunk {
        let id: String
        let header: Range<Int>
        let body: Range<Int>
        var isID3: Bool { id.lowercased() == "id3 " }
    }

    static func riffChunks(_ bytes: [UInt8], bigEndian: Bool) -> [Chunk] {
        var chunks: [Chunk] = []
        var o = 12
        while o + 8 <= bytes.count {
            let size = Int(bigEndian ? bytes.u32be(at: o + 4) : bytes.u32le(at: o + 4))
            let end = min(bytes.count, o + 8 + size)
            chunks.append(Chunk(id: bytes.ascii(o..<o + 4), header: o..<o + 8, body: o + 8..<end))
            o = o + 8 + size + (size & 1)
        }
        return chunks
    }

    /// WAV (RIFF, little endian) o AIFF (FORM, big endian): sustituye el chunk ID3 y,
    /// en WAV, actualiza LIST/INFO para que no queden título/álbum antiguos.
    static func rewriteChunked(_ bytes: [UInt8], _ edits: TagEdits, bigEndian: Bool) throws -> [UInt8] {
        let magic = bigEndian ? "FORM" : "RIFF"
        guard bytes.count >= 12, bytes.ascii(0..<4) == magic else { throw TagError.malformed("sin cabecera \(magic)") }
        let chunks = riffChunks(bytes, bigEndian: bigEndian)
        guard chunks.contains(where: { $0.id == (bigEndian ? "SSND" : "data") }) else { throw TagError.malformed("sin audio") }

        var tag = chunks.first { $0.isID3 }.flatMap { ID3Tag(bytes: Array(bytes[$0.body])) } ?? ID3Tag()
        apply(edits, to: &tag)

        func sized(_ n: Int) -> [UInt8] { bigEndian ? be32(n) : le32(n) }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            [UInt8](id.utf8) + sized(body.count) + body + (body.count & 1 == 1 ? [0] : [])
        }

        var out: [UInt8] = Array(bytes[0..<4]) + [0, 0, 0, 0] + Array(bytes[8..<12])
        out.reserveCapacity(bytes.count + 1024)
        for c in chunks where !c.isID3 {
            if !bigEndian, c.id == "LIST", c.body.count >= 4, bytes.ascii(c.body.lowerBound..<c.body.lowerBound + 4) == "INFO" {
                out += chunk("LIST", rewriteInfo(Array(bytes[c.body]), edits))
            } else {
                out += Array(bytes[c.header]) + bytes[c.body]
                if c.body.count & 1 == 1 { out.append(0) }
            }
        }
        out += chunk(bigEndian ? "ID3 " : "id3 ", tag.serialized())
        let total = sized(out.count - 8)
        out.replaceSubrange(4..<8, with: total)
        return out
    }

    /// Cuerpo de un LIST/INFO de WAV: INAM título, IART artista, IPRD álbum, IBPM.
    static func rewriteInfo(_ body: [UInt8], _ edits: TagEdits) -> [UInt8] {
        var entries: [(String, [UInt8])] = []
        var o = 4
        while o + 8 <= body.count {
            let size = Int(body.u32le(at: o + 4))
            let end = min(body.count, o + 8 + size)
            entries.append((body.ascii(o..<o + 4), Array(body[o + 8..<end])))
            o = o + 8 + size + (size & 1)
        }
        func set(_ id: String, _ value: String?) {
            guard let value else { return }
            let data = [UInt8](value.utf8) + [0]
            if let i = entries.firstIndex(where: { $0.0 == id }) { entries[i].1 = data } else { entries.append((id, data)) }
        }
        set("INAM", edits.title)
        set("IART", edits.artist)
        if edits.clearAlbum { entries.removeAll { $0.0 == "IPRD" } }
        if let g = edits.genre {
            if g.isEmpty { entries.removeAll { $0.0 == "IGNR" } } else { set("IGNR", g) }
        }
        if let bpm = edits.bpm, entries.contains(where: { $0.0 == "IBPM" }) { set("IBPM", formatBPM(bpm)) }

        var out: [UInt8] = [UInt8]("INFO".utf8)
        for (id, data) in entries {
            out += [UInt8](id.utf8) + le32(data.count) + data
            if data.count & 1 == 1 { out.append(0) }
        }
        return out
    }

    // MARK: M4A

    static func readM4A(_ url: URL) async throws -> FileTags {
        let items = try await AVURLAsset(url: url).load(.metadata)
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
            return try? await item.load(.stringValue)
        }
        var tags = FileTags()
        tags.title = await string(.commonIdentifierTitle)
        tags.artist = await string(.commonIdentifierArtist)
        tags.album = await string(.commonIdentifierAlbumName)
        tags.genre = await string(.iTunesMetadataUserGenre)
        if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataBeatsPerMin).first,
           let n = try? await item.load(.numberValue) {
            tags.bpm = n.doubleValue
        }
        return tags
    }

    static func writeM4A(_ url: URL, _ edits: TagEdits) async throws -> Data {
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.metadata)

        func replace(_ ids: [AVMetadataIdentifier], with value: (NSCopying & NSObjectProtocol)?, as id: AVMetadataIdentifier) {
            items.removeAll { item in item.identifier.map { ids.contains($0) } ?? false }
            if let value {
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = value
                items.append(item)
            }
        }
        if let t = edits.title {
            replace([.commonIdentifierTitle, .iTunesMetadataSongName], with: t as NSString, as: .iTunesMetadataSongName)
        }
        if let a = edits.artist {
            replace([.commonIdentifierArtist, .iTunesMetadataArtist], with: a as NSString, as: .iTunesMetadataArtist)
        }
        if edits.clearAlbum {
            replace([.commonIdentifierAlbumName, .iTunesMetadataAlbum], with: nil, as: .iTunesMetadataAlbum)
        }
        if let g = edits.genre {
            replace([.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .quickTimeMetadataGenre],
                    with: g.isEmpty ? nil : g as NSString, as: .iTunesMetadataUserGenre)
        }
        if let bpm = edits.bpm {
            replace([.iTunesMetadataBeatsPerMin], with: NSNumber(value: Int(bpm.rounded())), as: .iTunesMetadataBeatsPerMin)
        }
        switch edits.artwork {
        case .remove:
            replace([.commonIdentifierArtwork, .iTunesMetadataCoverArt], with: nil, as: .iTunesMetadataCoverArt)
        case .jpeg(let data):
            replace([.commonIdentifierArtwork, .iTunesMetadataCoverArt], with: data as NSData, as: .iTunesMetadataCoverArt)
        case nil:
            break
        }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TagError.malformed("no se pudo exportar el M4A")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        export.metadata = items
        try await export.export(to: tmp, as: .m4a)
        return try Data(contentsOf: tmp)
    }

    // MARK: Disco

    /// Reescribe el archivo sobre sí mismo (mismo inodo) para no romper el ID de Google Drive
    /// ni los atributos extendidos. Antes deja una copia temporal por si algo falla a mitad.
    static func overwriteInPlace(_ url: URL, with data: Data) throws {
        let safety = FileManager.default.temporaryDirectory
            .appendingPathComponent("djlibrary-\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: safety)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
        try? FileManager.default.removeItem(at: safety)
    }
}
