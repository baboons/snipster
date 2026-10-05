import AppKit

/// The menu bar icon: the app icon's scissors in a viewfinder, as a template
/// image so the system tints it for light and dark menu bars.
@MainActor
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            drawViewfinder()
            drawScissors()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snipster"
        return image
    }()

    private static func drawViewfinder() {
        let frame = NSRect(x: 1.5, y: 1.5, width: 15, height: 15)
        let arm: CGFloat = 3.4
        let radius: CGFloat = 2
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        for (corner, dx, dy) in [
            (NSPoint(x: frame.minX, y: frame.maxY), CGFloat(1), CGFloat(-1)),
            (NSPoint(x: frame.maxX, y: frame.maxY), -1, -1),
            (NSPoint(x: frame.maxX, y: frame.minY), -1, 1),
            (NSPoint(x: frame.minX, y: frame.minY), 1, 1),
        ] {
            path.move(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
            path.line(to: NSPoint(x: corner.x + dx * radius, y: corner.y))
            path.curve(to: NSPoint(x: corner.x, y: corner.y + dy * radius),
                       controlPoint1: NSPoint(x: corner.x + dx * radius * 0.45, y: corner.y),
                       controlPoint2: NSPoint(x: corner.x, y: corner.y + dy * radius * 0.45))
            path.line(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
        }
        path.stroke()
    }

    private static func drawScissors() {
        let pivot = NSPoint(x: 9, y: 9.1)
        for side: CGFloat in [-1, 1] {
            // Each blade leans away from its own ring, so the halves cross.
            let tip = NSPoint(x: pivot.x - side * 1.9, y: pivot.y + 5.2)
            let ring = NSPoint(x: pivot.x + side * 2.35, y: pivot.y - 3.6)

            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: pivot.x + side * 0.95, y: pivot.y - 0.9))
            blade.line(to: tip)
            blade.line(to: NSPoint(x: pivot.x - side * 0.75, y: pivot.y - 0.2))
            blade.close()
            blade.lineJoinStyle = .round
            blade.lineWidth = 0.5
            blade.fill()
            blade.stroke()

            let arm = NSBezierPath()
            arm.lineWidth = 1.3
            arm.lineCapStyle = .round
            arm.move(to: pivot)
            arm.line(to: NSPoint(x: ring.x - side * 0.75, y: ring.y + 1.15))
            arm.stroke()

            let loop = NSBezierPath(ovalIn: NSRect(x: ring.x - 1.45, y: ring.y - 1.45, width: 2.9, height: 2.9))
            loop.lineWidth = 1.2
            loop.stroke()
        }
    }
}
