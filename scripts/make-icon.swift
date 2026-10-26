// Tekent het app-icoon (1024×1024) en schrijft alle formaten naar de AppIcon-set.
// Gebruik: swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Schaduw onder de tegel.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x2A1F8F).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Achtergrond: indigo naar teal, met een zachte gloed linksboven.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x5B3FF0), color(0x3A2BB8), color(0x0E8FA8)])!
        .draw(in: tile, angle: -55)
    NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)])!
        .draw(fromCenter: NSPoint(x: 330, y: 820), radius: 0, toCenter: NSPoint(x: 330, y: 820), radius: 560, options: [])
    // Radarringen rond het symbool: "watch".
    let center = NSPoint(x: 512, y: 500)
    for (radius, alpha) in [(250.0, 0.16), (330.0, 0.10), (410.0, 0.06)] {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ring.lineWidth = 10
        color(0xFFFFFF, alpha).setStroke()
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Pull-request-symbool met lichte schaduw.
    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = color(0x10083F, 0.45)
    glyphShadow.shadowBlurRadius = 18
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
    glyphShadow.set()

    let white = color(0xFFFFFF)
    let line: CGFloat = 46
    let r: CGFloat = 74
    let leftX: CGFloat = 392, rightX: CGFloat = 632
    let topY: CGFloat = 680, bottomY: CGFloat = 320

    white.setStroke()
    // Linkerbranch: verticale lijn tussen twee cirkels.
    let left = NSBezierPath()
    left.move(to: NSPoint(x: leftX, y: topY - r))
    left.line(to: NSPoint(x: leftX, y: bottomY + r))
    left.lineWidth = line
    left.lineCapStyle = .round
    left.stroke()

    // Rechts: van de onderste cirkel omhoog, bocht naar links, pijl naar de linkerbranch.
    let right = NSBezierPath()
    right.move(to: NSPoint(x: rightX, y: bottomY + r))
    right.line(to: NSPoint(x: rightX, y: topY - 90))
    right.curve(to: NSPoint(x: rightX - 90, y: topY),
                controlPoint1: NSPoint(x: rightX, y: topY - 40),
                controlPoint2: NSPoint(x: rightX - 40, y: topY))
    right.line(to: NSPoint(x: 545, y: topY))
    right.lineWidth = line
    right.lineCapStyle = .round
    right.lineJoinStyle = .round
    right.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 600, y: topY + 60))
    arrow.line(to: NSPoint(x: 540, y: topY))
    arrow.line(to: NSPoint(x: 600, y: topY - 60))
    arrow.lineWidth = line
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()

    for point in [NSPoint(x: leftX, y: topY), NSPoint(x: leftX, y: bottomY), NSPoint(x: rightX, y: bottomY)] {
        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - r + 20, y: point.y - r + 20,
                                               width: (r - 20) * 2, height: (r - 20) * 2))
        ring.lineWidth = 40
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Meldingsstip rechtsboven.
    let dot = NSRect(x: 735, y: 735, width: 130, height: 130)
    NSGraphicsContext.saveGraphicsState()
    let dotShadow = NSShadow()
    dotShadow.shadowColor = color(0x000000, 0.3)
    dotShadow.shadowBlurRadius = 14
    dotShadow.shadowOffset = NSSize(width: 0, height: -6)
    dotShadow.set()
    NSGradient(colors: [color(0xFFB13B), color(0xFF5A36)])!.draw(in: NSBezierPath(ovalIn: dot), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let dotRing = NSBezierPath(ovalIn: dot.insetBy(dx: -4, dy: -4))
    dotRing.lineWidth = 8
    color(0xFFFFFF, 0.9).setStroke()
    dotRing.stroke()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
drawIcon()
NSGraphicsContext.restoreGraphicsState()
let master = NSImage(size: NSSize(width: size, height: size))
master.addRepresentation(rep)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try! scaled.representation(using: .png, properties: [:])!.write(to: outDir.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appending(path: "Contents.json"))
