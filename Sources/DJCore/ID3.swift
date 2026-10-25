import Foundation

struct ID3Frame {
    var id: String
    var flags: [UInt8]
    var data: [UInt8]
}

/// Tag ID3v2.3/2.4. Conserva los frames que no tocamos tal cual.
struct ID3Tag {
    var major: UInt8 = 3
    var frames: [ID3Frame] = []

    init() {}

    /// `bytes` debe empezar por "ID3". Devuelve nil si no hay tag.
    /// Los tags v2.2 o con unsynchronisation se descartan (se reescribe uno nuevo v2.3).
    init?(bytes: [UInt8]) {
        guard bytes.count >= 10, bytes.ascii(0..<3) == "ID3" else { return nil }
        let major = bytes[3], flags = bytes[5]
        let size = bytes.syncsafe(at: 6)
        guard major == 3 || major == 4, flags & 0x80 == 0 else { return }
        self.major = major
        let end = min(bytes.count, 10 + size)
        var o = 10
        if flags & 0x40 != 0, o + 4 <= end {
            o += major == 4 ? bytes.syncsafe(at: o) : 4 + Int(bytes.u32be(at: o))
        }
        while o + 10 <= end, bytes[o] != 0 {
            let id = bytes.ascii(o..<o + 4)
            let fsize = major == 4 ? bytes.syncsafe(at: o + 4) : Int(bytes.u32be(at: o + 4))
            let start = o + 10
            guard fsize >= 0, start + fsize <= end else { break }
            frames.append(ID3Frame(id: id, flags: Array(bytes[o + 8..<o + 10]), data: Array(bytes[start..<start + fsize])))
            o = start + fsize
        }
    }

    /// Longitud total del tag que empieza en `bytes` (cabecera + footer), o 0.
    static func length(in bytes: [UInt8]) -> Int {
        guard bytes.count >= 10, bytes.ascii(0..<3) == "ID3" else { return 0 }
        return 10 + bytes.syncsafe(at: 6) + (bytes[5] & 0x10 != 0 ? 10 : 0)
    }

    func text(_ id: String) -> String? {
        guard let f = frames.first(where: { $0.id == id }), let enc = f.data.first else { return nil }
        let body = Array(f.data.dropFirst())
        let s: String?
        switch enc {
        case 1: s = String(bytes: body, encoding: .utf16)
        case 2: s = String(bytes: body, encoding: .utf16BigEndian)
        case 3: s = String(bytes: body, encoding: .utf8)
        default: s = String(bytes: body, encoding: .isoLatin1)
        }
        return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).components(separatedBy: "\0").first
    }

    mutating func remove(_ id: String) { frames.removeAll { $0.id == id } }

    mutating func setText(_ id: String, _ value: String) {
        remove(id)
        var data: [UInt8]
        if let latin = value.data(using: .isoLatin1), value.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            data = [0] + [UInt8](latin)
        } else if major == 4 {
            data = [3] + [UInt8](value.utf8)
        } else {
            data = [1, 0xFF, 0xFE] + value.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        }
        frames.append(ID3Frame(id: id, flags: [0, 0], data: data))
    }

    mutating func setPicture(_ image: [UInt8], mime: String) {
        remove("APIC")
        let data: [UInt8] = [0] + [UInt8](mime.utf8) + [0, 3, 0] + image
        frames.append(ID3Frame(id: "APIC", flags: [0, 0], data: data))
    }

    func serialized(padding: Int = 0) -> [UInt8] {
        var body: [UInt8] = []
        for f in frames {
            body += [UInt8](f.id.utf8.prefix(4))
            body += major == 4 ? syncsafe32(f.data.count) : be32(f.data.count)
            body += f.flags
            body += f.data
        }
        body += [UInt8](repeating: 0, count: padding)
        return [UInt8]("ID3".utf8) + [major, 0, 0] + syncsafe32(body.count) + body
    }
}
