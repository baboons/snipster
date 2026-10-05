import AppKit

enum Tool: String, CaseIterable {
    case select, arrow, line, rectangle, ellipse, text, pen, highlighter, pixelate, blur, counter, crop

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlight"
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .counter: "Step Number"
        case .crop: "Crop"
        }
    }

    var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .blur: "drop"
        case .counter: "1.circle"
        case .crop: "crop"
        }
    }

    /// Single key that picks the tool while the canvas has focus.
    var shortcut: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "x"
        case .blur: "b"
        case .counter: "n"
        case .crop: "c"
        }
    }
}

enum RedactionStyle: Equatable {
    case pixelate
    case blur
}

/// One thing drawn on top of a screenshot. Geometry is in image points with
/// the origin at the top-left. Value semantics make undo a plain array copy.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case highlight(CGRect)
        case pen([CGPoint])
        case text(origin: CGPoint, string: String)
        case counter(center: CGPoint, number: Int)
        case redact(CGRect, RedactionStyle)
    }

    var id = UUID()
    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat

    // MARK: Derived sizes

    var fontSize: CGFloat { 12 + lineWidth * 4 }
    var counterRadius: CGFloat { 9 + lineWidth * 1.6 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color]
    }

    static func textSize(_ string: String, attributes: [NSAttributedString.Key: Any]) -> CGSize {
        let size = NSAttributedString(string: string.isEmpty ? " " : string, attributes: attributes).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: Geometry

    /// The tight box around the shape, ignoring stroke width.
    var frame: CGRect {
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .redact(let rect, _):
            return rect.standardized
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() { box = box.union(CGRect(origin: point, size: .zero)) }
            return box
        case .text(let origin, let string):
            return CGRect(origin: origin, size: Annotation.textSize(string, attributes: textAttributes))
        case .counter(let center, _):
            let radius = counterRadius
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Everything the shape can paint, including stroke, arrow head and shadow.
    var dirtyRect: CGRect {
        frame.insetBy(dx: -(lineWidth * 5 + 16), dy: -(lineWidth * 5 + 16))
    }

    /// Points the user can drag to reshape the annotation.
    var handles: [CGPoint] {
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return [from, to]
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .redact(let rect, _):
            let r = rect.standardized
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .pen, .text, .counter:
            return []
        }
    }

    mutating func moveHandle(_ index: Int, to point: CGPoint) {
        func resized(_ rect: CGRect) -> CGRect {
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            let fixed = corners[(index + 2) % 4]
            return CGRect(x: min(fixed.x, point.x), y: min(fixed.y, point.y),
                          width: abs(point.x - fixed.x), height: abs(point.y - fixed.y))
        }
        switch shape {
        case .arrow(let from, let to):
            shape = index == 0 ? .arrow(from: point, to: to) : .arrow(from: from, to: point)
        case .line(let from, let to):
            shape = index == 0 ? .line(from: point, to: to) : .line(from: from, to: point)
        case .rectangle(let rect): shape = .rectangle(resized(rect.standardized))
        case .ellipse(let rect): shape = .ellipse(resized(rect.standardized))
        case .highlight(let rect): shape = .highlight(resized(rect.standardized))
        case .redact(let rect, let style): shape = .redact(resized(rect.standardized), style)
        case .pen, .text, .counter: break
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        func moved(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + dx, y: point.y + dy) }
        switch shape {
        case .arrow(let from, let to): shape = .arrow(from: moved(from), to: moved(to))
        case .line(let from, let to): shape = .line(from: moved(from), to: moved(to))
        case .rectangle(let rect): shape = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case .ellipse(let rect): shape = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case .highlight(let rect): shape = .highlight(rect.offsetBy(dx: dx, dy: dy))
        case .redact(let rect, let style): shape = .redact(rect.offsetBy(dx: dx, dy: dy), style)
        case .pen(let points): shape = .pen(points.map(moved))
        case .text(let origin, let string): shape = .text(origin: moved(origin), string: string)
        case .counter(let center, let number): shape = .counter(center: moved(center), number: number)
        }
    }

    /// True when the shape is too small to be anything but an accidental click.
    var isDegenerate: Bool {
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) < 4
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .redact(let rect, _):
            return rect.width < 3 || rect.height < 3
        case .pen(let points):
            return points.count < 2
        case .text(_, let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter:
            return false
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = max(lineWidth / 2, 3) + tolerance
        switch shape {
        case .arrow(let from, let to), .line(let from, let to):
            return Annotation.distance(from: point, toSegment: from, to) <= reach
        case .rectangle(let rect):
            let r = rect.standardized
            return r.insetBy(dx: -reach, dy: -reach).contains(point) && !r.insetBy(dx: reach, dy: reach).contains(point)
        case .ellipse(let rect):
            let r = rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            // Normalised radius: 1 on the outline. Scale the tolerance by the smaller axis.
            let nx = (point.x - r.midX) / (r.width / 2)
            let ny = (point.y - r.midY) / (r.height / 2)
            let band = reach / (min(r.width, r.height) / 2)
            return abs(hypot(nx, ny) - 1) <= band
        case .highlight(let rect), .redact(let rect, _):
            return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .pen(let points):
            if points.count == 1 { return hypot(points[0].x - point.x, points[0].y - point.y) <= reach }
            return zip(points, points.dropFirst()).contains {
                Annotation.distance(from: point, toSegment: $0, $1) <= reach
            }
        case .text, .counter:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// Pixelated or blurred copies of regions of the base image, made by the Rust
/// core and kept until the region or image changes.
@MainActor
final class RedactionCache {
    private struct Key: Hashable {
        let image: ObjectIdentifier
        let rect: PixelRect
        let effect: RedactionEffect
    }

    private var patches: [Key: PixelImage] = [:]

    /// Returns the processed patch and where to draw it, in image points.
    func patch(for rect: CGRect, style: RedactionStyle, strength: CGFloat, in image: PixelImage) -> (PixelImage, CGRect)? {
        let pixels = PixelRect(rect.standardized, scale: image.scale).clamped(width: image.width, height: image.height)
        guard !pixels.isEmpty else { return nil }
        let effect: RedactionEffect
        switch style {
        case .pixelate: effect = .pixelate(block: Int(((4 + strength * 1.5) * image.scale).rounded()))
        case .blur: effect = .blur(radius: Int(((3 + strength * 1.5) * image.scale).rounded()))
        }
        let key = Key(image: ObjectIdentifier(image), rect: pixels, effect: effect)
        if let cached = patches[key] { return (cached, pixels.cgRect(scale: image.scale)) }
        // Dragging a region out makes one patch per mouse move; don't hoard them.
        if patches.count > 48 { patches.removeAll() }
        let patch = image.redacted(pixels, effect: effect)
        patches[key] = patch
        return (patch, pixels.cgRect(scale: image.scale))
    }
}

/// Draws annotations into a context whose origin is top-left (a flipped view
/// or the export bitmap), with `NSGraphicsContext.current` set to match.
@MainActor
struct AnnotationRenderer {
    let image: PixelImage
    let cache: RedactionCache
    /// The screenshot's outline when a decoration rounds its corners.
    /// Redactions are cut to it so they don't spill onto the backdrop.
    var contentClip: CGPath?

    /// CoreGraphics draws images bottom-up, so flip around the target rect.
    static func draw(_ cgImage: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    func draw(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let color = annotation.color.cgColor
        let width = annotation.lineWidth
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.setStrokeColor(color)
        context.setFillColor(color)

        switch annotation.shape {
        case .redact(let rect, let style):
            if let (patch, target) = cache.patch(for: rect, style: style, strength: width, in: image) {
                if let contentClip {
                    context.addPath(contentClip)
                    context.clip()
                }
                context.interpolationQuality = .none
                AnnotationRenderer.draw(patch.cgImage, in: target, context: context)
            }
        case .highlight(let rect):
            context.setBlendMode(.multiply)
            context.setFillColor(annotation.color.withAlphaComponent(0.45).cgColor)
            context.fill(rect.standardized)
        case .arrow(let from, let to):
            applyShadow(context)
            context.addPath(AnnotationRenderer.arrowPath(from: from, to: to, width: width))
            context.setLineWidth(max(width * 0.35, 1))
            context.drawPath(using: .fillStroke)
        case .line(let from, let to):
            applyShadow(context)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        case .rectangle(let rect):
            applyShadow(context)
            let r = rect.standardized
            let radius = min(3, min(r.width, r.height) / 2)
            context.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .ellipse(let rect):
            applyShadow(context)
            context.strokeEllipse(in: rect.standardized)
        case .pen(let points):
            applyShadow(context)
            context.addPath(AnnotationRenderer.smoothPath(through: points))
            context.strokePath()
        case .text(let origin, let string):
            drawText(string, at: origin, annotation: annotation)
        case .counter(let center, let number):
            applyShadow(context)
            let radius = annotation.counterRadius
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
                .foregroundColor: annotation.color.isLight ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        }
    }

    private func applyShadow(_ context: CGContext) {
        context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    }

    private func drawText(_ string: String, at origin: CGPoint, annotation: Annotation) {
        // A contrasting outline keeps text readable on any background.
        var outline = annotation.textAttributes
        outline[.strokeColor] = annotation.color.isLight ? NSColor.black.withAlphaComponent(0.75) : NSColor.white
        outline[.strokeWidth] = 14
        outline[.foregroundColor] = NSColor.clear
        NSAttributedString(string: string, attributes: outline).draw(at: origin)
        NSAttributedString(string: string, attributes: annotation.textAttributes).draw(at: origin)
    }

    /// A tapered shaft that swells into a swept-back head.
    static func arrowPath(from tail: CGPoint, to tip: CGPoint, width: CGFloat) -> CGPath {
        let length = max(hypot(tip.x - tail.x, tip.y - tail.y), 0.001)
        let ux = (tip.x - tail.x) / length, uy = (tip.y - tail.y) / length
        let nx = -uy, ny = ux
        let headLength = min(max(width * 4.5, 13), length * 0.7)
        let headHalf = headLength * 0.5
        let neckHalf = min(max(width * 0.7, 1.2), headHalf * 0.6)
        let tailHalf = max(width * 0.22, 0.6)
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - ux * along + nx * across, y: tip.y - uy * along + ny * across)
        }
        let path = CGMutablePath()
        path.move(to: point(length, tailHalf))
        path.addLine(to: point(headLength * 0.82, neckHalf))
        path.addLine(to: point(headLength, headHalf))
        path.addLine(to: tip)
        path.addLine(to: point(headLength, -headHalf))
        path.addLine(to: point(headLength * 0.82, -neckHalf))
        path.addLine(to: point(length, -tailHalf))
        path.closeSubpath()
        return path
    }

    /// Rounds the corners of a freehand stroke by curving through midpoints.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

extension NSColor {
    /// Whether black reads better than white on top of this colour.
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent > 0.6
    }
}
