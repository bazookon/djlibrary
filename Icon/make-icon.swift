// Dibuja el icono de la app (1024×1024 PNG).
// Uso: swift Icon/make-icon.swift Icon/icon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let green = NSColor(srgbRed: 0.18, green: 0.91, blue: 0.48, alpha: 1)
let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)

// Fondo: cuadrado redondeado estilo macOS (margen de la plantilla de Apple: 100 px).
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
tilePath.fill()
ctx.restoreGState()
tilePath.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
    .draw(in: tilePath, angle: -90)

// Vinilo.
let center = CGPoint(x: 512, y: 560)
let radius: CGFloat = 285
func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}
NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1).setFill()
circle(radius).fill()
// Surcos.
for i in 0..<14 {
    let r = radius - 18 - CGFloat(i) * 12
    NSColor.white.withAlphaComponent(i % 3 == 0 ? 0.10 : 0.05).setStroke()
    let p = circle(r)
    p.lineWidth = 2
    p.stroke()
}
// Reflejo.
ctx.saveGState()
circle(radius).addClip()
let shine = NSBezierPath()
shine.move(to: center)
shine.appendArc(withCenter: center, radius: radius, startAngle: 35, endAngle: 65)
shine.close()
NSColor.white.withAlphaComponent(0.10).setFill()
shine.fill()
let shine2 = NSBezierPath()
shine2.move(to: center)
shine2.appendArc(withCenter: center, radius: radius, startAngle: 215, endAngle: 245)
shine2.close()
shine2.fill()
ctx.restoreGState()
// Etiqueta verde y agujero.
green.setFill()
circle(92).fill()
NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1).setFill()
circle(14).fill()

// Beatgrid: marcas bajo el disco, con un downbeat naranja.
let gridY: CGFloat = 175
for i in 0..<16 {
    let x = 232 + CGFloat(i) * 37.3
    let isDownbeat = i % 4 == 0
    (isDownbeat ? orange : NSColor.white.withAlphaComponent(0.55)).setFill()
    let h: CGFloat = isDownbeat ? 64 : 36
    NSBezierPath(roundedRect: NSRect(x: x - 5, y: gridY, width: 10, height: h), xRadius: 5, yRadius: 5).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok \(out)")
