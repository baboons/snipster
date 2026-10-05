// Renders Snipster's app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift build/AppIcon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

/// Draws one half of the scissors in the current fill colour: a blade above
/// the pivot and, on the opposite side below it, an arm ending in a finger
/// ring. `side` is -1 for the half whose ring is on the left.
func drawScissorHalf(pivot: NSPoint, side: CGFloat) {
    // The blade leans away from its own ring, so the two halves cross.
    let lean: CGFloat = 20 * .pi / 180
    let blade = NSPoint(x: -side * sin(lean), y: cos(lean))
    let normal = NSPoint(x: blade.y, y: -blade.x)
    func along(_ distance: CGFloat, _ across: CGFloat = 0) -> NSPoint {
        point(pivot.x + blade.x * distance + normal.x * across, pivot.y + blade.y * distance + normal.y * across)
    }

    // Blade: wide at the pivot, tapering to a rounded point.
    let path = NSBezierPath()
    path.move(to: along(-46, -36))
    path.line(to: along(196, -19))
    path.curve(to: along(282, 0), controlPoint1: along(240, -16), controlPoint2: along(274, -10))
    path.curve(to: along(196, 19), controlPoint1: along(274, 10), controlPoint2: along(240, 16))
    path.line(to: along(-46, 36))
    path.close()
    path.fill()

    // Arm and ring. The arm stops inside the ring's band, leaving the hole clear.
    let ringCenter = point(pivot.x + side * 114, pivot.y - 178)
    let ringRadius: CGFloat = 66
    let reach = hypot(ringCenter.x - pivot.x, ringCenter.y - pivot.y)
    let towards = NSPoint(x: (ringCenter.x - pivot.x) / reach, y: (ringCenter.y - pivot.y) / reach)
    let arm = NSBezierPath()
    arm.lineWidth = 50
    arm.lineCapStyle = .round
    arm.move(to: pivot)
    let armLength = reach - ringRadius - 8
    arm.line(to: point(pivot.x + towards.x * armLength, pivot.y + towards.y * armLength))
    arm.stroke()

    let ring = NSBezierPath(ovalIn: NSRect(x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
                                           width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = 40
    ring.stroke()
}

/// Draws on a 1024×1024 canvas (origin bottom-left). The smallest sizes get
/// a `simplified` icon: bigger scissors and no viewfinder, which would only
/// turn to mush at 16 pixels.
func draw(simplified: Bool) {
    // Apple's icon grid: 824pt body centered in 1024.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x6D28D9).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Indigo to violet to pink: the same sweep as the editor's default backdrop.
    NSGradient(colors: [color(0x4F46E5), color(0x7C3AED), color(0xE11D74)], atLocations: [0, 0.48, 1], colorSpace: .sRGB)!
        .draw(in: squircle, angle: -45)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    // Light from above, a little weight at the bottom.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 540, width: 824, height: 384), angle: -90)
    NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.18)])!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 300), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let glyph = NSShadow()
    glyph.shadowColor = color(0x2E1065, 0.45)
    glyph.shadowBlurRadius = 22
    glyph.shadowOffset = NSSize(width: 0, height: -10)

    if !simplified { drawViewfinder(shadow: glyph) }
    drawScissors(scale: simplified ? 1.3 : 1, shadow: glyph)
}

/// The selection being snipped: a lit region with viewfinder corners.
func drawViewfinder(shadow glyph: NSShadow) {
    let region = NSRect(x: 226, y: 226, width: 572, height: 572)
    color(0xFFFFFF, 0.12).setFill()
    NSBezierPath(roundedRect: region, xRadius: 44, yRadius: 44).fill()

    let arm: CGFloat = 112
    let radius: CGFloat = 44
    let brackets = NSBezierPath()
    brackets.lineWidth = 46
    brackets.lineCapStyle = .round
    for (corner, dx, dy) in [
        (point(region.minX, region.maxY), CGFloat(1), CGFloat(-1)),
        (point(region.maxX, region.maxY), -1, -1),
        (point(region.maxX, region.minY), -1, 1),
        (point(region.minX, region.minY), 1, 1),
    ] {
        brackets.move(to: point(corner.x + dx * arm, corner.y))
        brackets.line(to: point(corner.x + dx * radius, corner.y))
        brackets.curve(to: point(corner.x, corner.y + dy * radius),
                       controlPoint1: point(corner.x + dx * radius * 0.45, corner.y),
                       controlPoint2: point(corner.x, corner.y + dy * radius * 0.45))
        brackets.line(to: point(corner.x, corner.y + dy * arm))
    }
    NSGraphicsContext.saveGraphicsState()
    glyph.set()
    NSColor.white.setStroke()
    brackets.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

/// Scissors, open, tips up. The far half is a shade darker so the crossing
/// reads as one blade over the other. Each half is composited as a group, so
/// its parts share one shadow instead of shading each other.
func drawScissors(scale: CGFloat, shadow glyph: NSShadow) {
    let pivot = point(512, 508)
    let context = NSGraphicsContext.current!.cgContext
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    // Tips and rings are about equally far from the pivot, so grow around it.
    let grow = NSAffineTransform()
    grow.translateX(by: pivot.x, yBy: pivot.y)
    grow.scale(by: scale)
    grow.translateX(by: -pivot.x, yBy: -pivot.y)
    grow.concat()
    for (side, fill) in [(CGFloat(1), color(0xE4DCFF)), (CGFloat(-1), NSColor.white)] {
        NSGraphicsContext.saveGraphicsState()
        glyph.set()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fill.set()
        drawScissorHalf(pivot: pivot, side: side)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }
    // The screw the blades turn on.
    color(0x7C3AED).setFill()
    NSBezierPath(ovalIn: NSRect(x: pivot.x - 15, y: pivot.y - 15, width: 30, height: 30)).fill()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for size in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size.pixels, pixelsHigh: size.pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(simplified: size.pixels <= 32)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(size.name).png"))
}
print("Wrote \(sizes.count) icons to \(out.path)")
