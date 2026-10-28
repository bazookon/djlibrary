import Foundation

/// Preferencias de rekordbox (rekordbox3.settings, un XML de <VALUE name=… val=…/>).
/// Solo tocamos lo necesario para que rekordbox lea nuestro XML:
///   bridgeImportedLibraryFile = ruta del rekordbox.xml (Preferencias → Avanzado → Base de datos → rekordbox xml)
///   showRbXml = 1 (muestra «rekordbox xml» en la barra lateral)
public enum RekordboxSettings {
    public static let bundleIdentifier = "com.pioneerdj.rekordboxdj"

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings")
    }

    public static func value(_ name: String, in text: String) -> String? {
        guard let r = text.range(of: #"<VALUE name="\#(name)" val="([^"]*)"/>"#, options: .regularExpression) else { return nil }
        let match = String(text[r])
        guard let v = match.range(of: #"val="([^"]*)""#, options: .regularExpression) else { return nil }
        return unescape(String(match[v].dropFirst(5).dropLast()))
    }

    /// True si rekordbox ya apunta a `xmlPath` y muestra el nodo «rekordbox xml».
    public static func isConfigured(xmlPath: String, settings: URL = url) -> Bool {
        guard let text = try? String(contentsOf: settings, encoding: .utf8) else { return false }
        return value("bridgeImportedLibraryFile", in: text) == xmlPath && value("showRbXml", in: text) == "1"
    }

    /// Escribe los ajustes (rekordbox debe estar cerrado: los sobrescribe al salir).
    /// Deja una copia "rekordbox3.settings.djlibrary-backup" la primera vez.
    public static func configure(xmlPath: String, settings url: URL = url) throws {
        var text = try String(contentsOf: url, encoding: .utf8)
        let backup = url.deletingLastPathComponent().appendingPathComponent("rekordbox3.settings.djlibrary-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        set("bridgeImportedLibraryFile", escape(xmlPath), in: &text)
        set("showRbXml", "1", in: &text)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func set(_ name: String, _ val: String, in text: inout String) {
        let line = #"<VALUE name="\#(name)" val="\#(val)"/>"#
        if let r = text.range(of: #"<VALUE name="\#(name)" val="[^"]*"/>"#, options: .regularExpression) {
            text.replaceSubrange(r, with: line)
        } else if let end = text.range(of: "</PROPERTIES>", options: .backwards) {
            text.insert(contentsOf: "  \(line)\n", at: end.lowerBound)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
