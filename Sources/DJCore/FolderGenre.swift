import Foundation

public enum FolderGenre {
    /// Género a partir de la carpeta del archivo, saltando carpetas que son solo números (años):
    ///   ".../Dj O!/Regueton/2026/x.wav" → "Regueton", ".../Dj O!/Mambo/x.aif" → "Mambo".
    public static func genre(for url: URL) -> String? {
        var dir = url.deletingLastPathComponent()
        for _ in 0..<4 {
            let name = dir.lastPathComponent
            guard !name.isEmpty, name != "/" else { return nil }
            if name.range(of: #"^\d+$"#, options: .regularExpression) == nil { return name }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
