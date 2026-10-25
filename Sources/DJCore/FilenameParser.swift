import Foundation

/// Saca artista y título del nombre de archivo, p. ej.
///   "085 J Alvarez - Junto al Amanecer (Out Acapella) [XINO PV].wav"
///   → artista "J Alvarez", título "Junto al Amanecer (Out Acapella) [XINO PV]"
public enum FilenameParser {
    public static func parse(_ filename: String) -> (artist: String?, title: String) {
        var name = (filename as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ")

        // Prefijos de BPM / número de pista: "085 ", "(092) ", "100. ", "090 - 104 - ".
        let prefix = #"^\s*\(?\d{2,3}\)?\s*(?:[.\-–]\s*|\s+)"#
        while let r = name.range(of: prefix, options: .regularExpression) { name.removeSubrange(r) }
        // Etiquetas de género al principio: "[In Pop Urbano - Arabe] - ".
        if let r = name.range(of: #"^\s*\[[^\]]*\]\s*[\-–]?\s*"#, options: .regularExpression) { name.removeSubrange(r) }
        // BPM al final: " 99 BPM", " - 98bpm - Jpr" se deja; solo el sufijo directo.
        if let r = name.range(of: #"\s*[\-–]?\s*\d{2,3}\s*bpm\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(r)
        }

        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        for sep in [" - ", " – ", " — "] {
            if let r = name.range(of: sep) {
                let artist = name[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty && !title.isEmpty { return (artist, title) }
            }
        }
        return (nil, name)
    }
}
