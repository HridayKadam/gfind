// Draws the app icon and writes an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1).cgColor,
        NSColor(red: 0.93, green: 0.92, blue: 0.97, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // A 3x2 shelf of pastel cards, one per kind of file.
    let colors: [NSColor] = [
        NSColor(red: 0.98, green: 0.45, blue: 0.55, alpha: 1), NSColor(red: 0.55, green: 0.45, blue: 0.98, alpha: 1),
        NSColor(red: 0.98, green: 0.62, blue: 0.25, alpha: 1), NSColor(red: 0.25, green: 0.62, blue: 0.98, alpha: 1),
        NSColor(red: 0.85, green: 0.72, blue: 0.25, alpha: 1), NSColor(red: 0.30, green: 0.78, blue: 0.55, alpha: 1),
    ]
    let card: CGFloat = 200 * s, gap: CGFloat = 36 * s
    let x0 = 512 * s - (3 * card + 2 * gap) / 2, y0 = 300 * s
    for i in 0..<6 {
        let r = CGRect(x: x0 + CGFloat(i % 3) * (card + gap), y: y0 + CGFloat(1 - i / 3) * (card + gap), width: card, height: card)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 44 * s, cornerHeight: 44 * s, transform: nil))
        ctx.setFillColor(colors[i].cgColor); ctx.fillPath()
    }

    // Magnifying glass over the bottom-right corner.
    let c = CGPoint(x: 640 * s, y: 330 * s), rad: CGFloat = 150 * s
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.setLineWidth(46 * s)
    ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
    ctx.setLineCap(.round); ctx.setLineWidth(64 * s)
    ctx.move(to: CGPoint(x: c.x + rad * 0.75, y: c.y - rad * 0.75))
    ctx.addLine(to: CGPoint(x: c.x + rad * 1.55, y: c.y - rad * 1.55))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
