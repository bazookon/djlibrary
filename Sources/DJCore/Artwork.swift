import AppKit
import CryptoKit
import Foundation

public enum Artwork {
    /// Convierte el logo en un JPEG cuadrado (fondo negro, logo centrado) apto para embeber.
    public static func prepareLogo(from url: URL, size: Int = 600) throws -> Data {
        guard let image = NSImage(contentsOf: url) else { throw TagError.malformed("no se pudo leer la imagen") }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw TagError.malformed("no se pudo crear la imagen")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let s = image.size
        let scale = min(Double(size) / s.width, Double(size) / s.height)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw TagError.malformed("no se pudo codificar el JPEG")
        }
        return jpeg
    }

    /// Engine identifica el arte por el SHA1 de los bytes de la imagen embebida.
    public static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    /// Engine muestra las carátulas desde una caché: "Engine Library/Artwork/<base64url(sha1)>.jpg",
    /// una miniatura JPEG de 256×256. Si no existe, la pista sale sin carátula aunque el archivo la tenga.
    public static func cacheURL(libraryRoot: URL, sha1: Data) -> URL {
        let name = sha1.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return libraryRoot.appendingPathComponent("Artwork", isDirectory: true).appendingPathComponent(name + ".jpg")
    }

    /// Crea la miniatura en la caché de Engine si falta.
    public static func ensureEngineCache(libraryRoot: URL, image: Data) throws {
        let url = cacheURL(libraryRoot: libraryRoot, sha1: sha1(image))
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try thumbnail(image, size: 256).write(to: url)
    }

    static func thumbnail(_ data: Data, size: Int) throws -> Data {
        guard let image = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw TagError.malformed("no se pudo crear la miniatura")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw TagError.malformed("no se pudo codificar la miniatura")
        }
        return jpeg
    }
}
