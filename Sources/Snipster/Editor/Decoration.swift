import AppKit

/// A ready-made gradient to put behind a screenshot.
struct GradientPreset {
    let id: String
    let colors: [NSColor]
    /// Direction in degrees: 0 runs left to right, 90 top to bottom.
    let angle: CGFloat

    private init(_ id: String, _ hex: [UInt32], angle: CGFloat) {
        self.id = id
        self.colors = hex.map(NSColor.init(hex:))
        self.angle = angle
    }

    static let all: [GradientPreset] = [
        GradientPreset("aurora", [0x4F46E5, 0x7C3AED, 0xDB2777], angle: 40),
        GradientPreset("ocean", [0x22D3EE, 0x2563EB, 0x4338CA], angle: 40),
        GradientPreset("sunset", [0xFBBF24, 0xF97316, 0xDB2777], angle: 40),
        GradientPreset("forest", [0x6EE7B7, 0x10B981, 0x0F766E], angle: 40),
        GradientPreset("peach", [0xFDE68A, 0xFDA4AF, 0xF0ABFC], angle: 40),
        GradientPreset("sky", [0xE0F2FE, 0xA5B4FC], angle: 60),
        GradientPreset("graphite", [0x52525B, 0x18181B], angle: 90),
        GradientPreset("paper", [0xFAFAFA, 0xE4E4E7], angle: 90),
    ]

    static func named(_ id: String) -> GradientPreset? {
        all.first { $0.id == id }
    }
}

/// What a screenshot is dressed in before it leaves the editor: a macOS-style
/// window frame, a background, and the space, rounding and shadow around it.
struct Decoration: Equatable {
    enum WindowStyle: String, CaseIterable {
        case none, light, dark
    }

    enum Backdrop: Equatable {
        /// Nothing behind the picture: the padding and corners stay transparent.
        case none
        case solid(NSColor)
        case gradient(String)
        /// The current desktop picture.
        case wallpaper
    }

    var window = WindowStyle.none
    /// Shown in the window frame's title bar.
    var title = ""
    var backdrop = Backdrop.none
    /// Space between the picture and the edge of the result, in points.
    var padding: CGFloat = 56
    var cornerRadius: CGFloat = 12
    var hasShadow = true

    static let titleBarHeight: CGFloat = 32
    static let paddingRange: ClosedRange<CGFloat> = 0...160
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...32

    /// True when the screenshot is left exactly as captured.
    var isEmpty: Bool { window == .none && backdrop == .none }

    private var inset: CGFloat { isEmpty ? 0 : padding }
    private var titleBar: CGFloat { window == .none ? 0 : Decoration.titleBarHeight }

    /// Where the screenshot's top-left corner sits in the decorated picture.
    var contentOrigin: CGPoint { CGPoint(x: inset, y: inset + titleBar) }

    func outerSize(for imageSize: CGSize) -> CGSize {
        CGSize(width: imageSize.width + inset * 2, height: imageSize.height + titleBar + inset * 2)
    }

    /// The window frame's outline (title bar plus screenshot), or just the
    /// screenshot when there is no frame.
    func windowRect(for imageSize: CGSize) -> CGRect {
        CGRect(x: inset, y: inset, width: imageSize.width, height: imageSize.height + titleBar)
    }

    func radius(for imageSize: CGSize) -> CGFloat {
        let rect = windowRect(for: imageSize)
        return isEmpty ? 0 : min(cornerRadius, min(rect.width, rect.height) / 2)
    }

    /// Whether the decorated picture has no transparent pixels.
    func isOpaque(around image: PixelImage) -> Bool {
        isEmpty ? image.opaque : backdrop != .none
    }

    // MARK: Persistence

    var dictionary: [String: Any] {
        let backdropValue: String
        switch backdrop {
        case .none: backdropValue = "none"
        case .solid(let color): backdropValue = "solid:\(color.hexString)"
        case .gradient(let id): backdropValue = "gradient:\(id)"
        case .wallpaper: backdropValue = "wallpaper"
        }
        return [
            "window": window.rawValue, "backdrop": backdropValue, "padding": Double(padding),
            "cornerRadius": Double(cornerRadius), "shadow": hasShadow,
        ]
    }

    init() {}

    /// Restores a saved style. The title is per screenshot and never saved.
    init(dictionary: [String: Any]) {
        if let raw = dictionary["window"] as? String, let style = WindowStyle(rawValue: raw) { window = style }
        if let value = dictionary["backdrop"] as? String {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("solid", let hex?): backdrop = NSColor(hexString: hex).map(Backdrop.solid) ?? .none
            case ("gradient", let id?): backdrop = GradientPreset.named(id) == nil ? .none : .gradient(id)
            case ("wallpaper", _): backdrop = .wallpaper
            default: backdrop = .none
            }
        }
        if let value = dictionary["padding"] as? Double {
            padding = min(max(CGFloat(value), Decoration.paddingRange.lowerBound), Decoration.paddingRange.upperBound)
        }
        if let value = dictionary["cornerRadius"] as? Double {
            cornerRadius = min(max(CGFloat(value), Decoration.cornerRadiusRange.lowerBound), Decoration.cornerRadiusRange.upperBound)
        }
        if let value = dictionary["shadow"] as? Bool { hasShadow = value }
    }
}

/// Draws a `Decoration` around a screenshot. Works in a context whose origin
/// is top-left (a flipped view or the export bitmap) with
/// `NSGraphicsContext.current` set to match.
@MainActor
final class DecorationRenderer {
    private struct ShadowKey: Equatable {
        /// Only set when the shadow follows the picture's own outline.
        let image: ObjectIdentifier?
        let outer: CGSize
        let shape: CGRect
        let radius: CGFloat
    }

    private var shadow: (key: ShadowKey, image: PixelImage)?

    /// Distance the shadow falls, its softness and its strength.
    private static let shadowDrop: CGFloat = 16
    private static let shadowBlur: CGFloat = 22
    private static let shadowOpacity: CGFloat = 0.45
    /// The shadow is rendered small and scaled up; it has no detail to lose.
    private static let shadowScale: CGFloat = 0.25

    /// Draws backdrop, shadow, window frame and the screenshot itself.
    func draw(_ decoration: Decoration, around image: PixelImage, in context: CGContext,
              interpolation: CGInterpolationQuality) {
        let size = image.size
        let content = CGRect(origin: decoration.contentOrigin, size: size)
        guard !decoration.isEmpty else {
            context.interpolationQuality = interpolation
            AnnotationRenderer.draw(image.cgImage, in: content, context: context)
            return
        }
        let outer = CGRect(origin: .zero, size: decoration.outerSize(for: size))
        let windowRect = decoration.windowRect(for: size)
        let radius = decoration.radius(for: size)
        let shape = CGPath(roundedRect: windowRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        drawBackdrop(decoration.backdrop, in: outer, context: context)
        if decoration.hasShadow {
            let image = shadowImage(for: decoration, around: image, outer: outer.size, shape: windowRect, radius: radius)
            context.saveGState()
            context.setAlpha(DecorationRenderer.shadowOpacity)
            context.interpolationQuality = .high
            AnnotationRenderer.draw(image.cgImage, in: outer, context: context)
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shape)
        context.clip()
        if decoration.window != .none {
            let dark = decoration.window == .dark
            context.setFillColor(NSColor(hex: dark ? 0x1E1E1E : 0xFFFFFF).cgColor)
            context.fill(windowRect)
        }
        context.interpolationQuality = interpolation
        AnnotationRenderer.draw(image.cgImage, in: content, context: context)
        if decoration.window != .none {
            drawTitleBar(decoration, in: windowRect, context: context)
        }
        context.restoreGState()

        if decoration.window != .none {
            // The hairline every macOS window has around it.
            let dark = decoration.window == .dark
            context.saveGState()
            context.addPath(CGPath(roundedRect: windowRect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.setStrokeColor(NSColor.black.withAlphaComponent(dark ? 0.55 : 0.2).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
            if dark {
                let inner = windowRect.insetBy(dx: 0.75, dy: 0.75)
                context.addPath(CGPath(roundedRect: inner, cornerWidth: max(radius - 0.75, 0),
                                       cornerHeight: max(radius - 0.75, 0), transform: nil))
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
                context.strokePath()
            }
            context.restoreGState()
        }
    }

    /// The outline redactions must stay inside, in image coordinates, or nil
    /// when the screenshot keeps its square corners.
    func contentClip(for decoration: Decoration, imageSize: CGSize) -> CGPath? {
        let radius = decoration.radius(for: imageSize)
        guard radius > 0 else { return nil }
        let origin = decoration.contentOrigin
        let rect = decoration.windowRect(for: imageSize).offsetBy(dx: -origin.x, dy: -origin.y)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Rasterises the decorated screenshot; `overlay` draws on top of it in
    /// image coordinates (that is where annotations live).
    func render(_ decoration: Decoration, around image: PixelImage, overlay: ((CGContext) -> Void)? = nil) -> PixelImage {
        let origin = decoration.contentOrigin
        return PixelImage(size: decoration.outerSize(for: image.size), scale: image.scale,
                          opaque: decoration.isOpaque(around: image)) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            // Exported at the capture's own scale, so the pixels map one to one.
            self.draw(decoration, around: image, in: context, interpolation: .none)
            context.interpolationQuality = .high
            context.translateBy(x: origin.x, y: origin.y)
            overlay?(context)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Pieces

    private func drawBackdrop(_ backdrop: Decoration.Backdrop, in rect: CGRect, context: CGContext) {
        switch backdrop {
        case .none:
            break
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .gradient(let id):
            guard let preset = GradientPreset.named(id) else { return }
            DecorationRenderer.fill(rect, with: preset, context: context)
        case .wallpaper:
            guard let wallpaper = Wallpaper.image else {
                context.setFillColor(NSColor(hex: 0x3F3F46).cgColor)
                context.fill(rect)
                return
            }
            // Fill the area, cropping whatever doesn't fit.
            let scale = max(rect.width / CGFloat(wallpaper.width), rect.height / CGFloat(wallpaper.height))
            let size = CGSize(width: CGFloat(wallpaper.width) * scale, height: CGFloat(wallpaper.height) * scale)
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .high
            AnnotationRenderer.draw(wallpaper, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                         width: size.width, height: size.height), context: context)
            context.restoreGState()
        }
    }

    static func fill(_ rect: CGRect, with preset: GradientPreset, context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: PixelImage.colorSpace,
                                        colors: preset.colors.map(\.cgColor) as CFArray, locations: nil)
        else { return }
        // Span the gradient across the rectangle's extent along its direction,
        // so the end colours land exactly in the corners.
        let angle = preset.angle * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let reach = (abs(rect.width * direction.x) + abs(rect.height * direction.y)) / 2
        let start = CGPoint(x: rect.midX - direction.x * reach, y: rect.midY - direction.y * reach)
        let end = CGPoint(x: rect.midX + direction.x * reach, y: rect.midY + direction.y * reach)
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private func drawTitleBar(_ decoration: Decoration, in windowRect: CGRect, context: CGContext) {
        let dark = decoration.window == .dark
        let bar = CGRect(x: windowRect.minX, y: windowRect.minY, width: windowRect.width, height: Decoration.titleBarHeight)
        context.setFillColor(NSColor(hex: dark ? 0x38383A : 0xF1F1F2).cgColor)
        context.fill(bar)
        context.setFillColor(NSColor.black.withAlphaComponent(dark ? 0.5 : 0.12).cgColor)
        context.fill(CGRect(x: bar.minX, y: bar.maxY - 0.5, width: bar.width, height: 0.5))

        // Close, minimise, zoom.
        for (index, hex) in [(0, 0xFF5F57), (1, 0xFEBC2E), (2, 0x28C840)] as [(Int, UInt32)] {
            let light = CGRect(x: bar.minX + 14 + CGFloat(index) * 20, y: bar.midY - 6, width: 12, height: 12)
            context.setFillColor(NSColor(hex: hex).cgColor)
            context.fillEllipse(in: light)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(0.5)
            context.strokeEllipse(in: light.insetBy(dx: 0.25, dy: 0.25))
        }

        let title = decoration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep clear of the buttons, and centred, by reserving the same space on both sides.
        let room = bar.insetBy(dx: 80, dy: 0)
        guard !title.isEmpty, room.width > 20 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(hex: dark ? 0xE4E4E7 : 0x3F3F46),
            .paragraphStyle: style,
        ])
        let height = ceil(text.size().height)
        text.draw(with: CGRect(x: room.minX, y: bar.midY - height / 2, width: room.width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A soft shadow for the framed picture, as a translucent black image the
    /// size of the whole result. Blurred by the Rust core and cached, since
    /// the canvas redraws far more often than the geometry changes.
    private func shadowImage(for decoration: Decoration, around image: PixelImage, outer: CGSize,
                             shape: CGRect, radius: CGFloat) -> PixelImage {
        // A captured window brings its own outline (rounded corners in its
        // alpha channel); a frame or an opaque crop is a plain rounded rect.
        let followsImage = !image.opaque && decoration.window == .none
        let key = ShadowKey(image: followsImage ? ObjectIdentifier(image) : nil, outer: outer, shape: shape, radius: radius)
        if let shadow, shadow.key == key { return shadow.image }

        let cast = shape.offsetBy(dx: 0, dy: DecorationRenderer.shadowDrop)
        let mask = PixelImage(size: outer, scale: DecorationRenderer.shadowScale, opaque: false) { context in
            context.setFillColor(NSColor.black.cgColor)
            if followsImage {
                AnnotationRenderer.draw(image.cgImage, in: cast, context: context)
                // Keep the picture's coverage, replace its colour with black.
                context.setBlendMode(.sourceIn)
                context.fill(CGRect(origin: .zero, size: outer))
            } else {
                context.addPath(CGPath(roundedRect: cast, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        let blur = Int((DecorationRenderer.shadowBlur * DecorationRenderer.shadowScale).rounded())
        let blurred = mask.redacted(PixelRect(x: 0, y: 0, width: mask.width, height: mask.height), effect: .blur(radius: blur))
        shadow = (key, blurred)
        return blurred
    }
}

/// The desktop picture, loaded once and scaled down to a sensible size.
@MainActor
enum Wallpaper {
    private static var loaded = false
    private static var cached: CGImage?

    static var image: CGImage? {
        if loaded { return cached }
        loaded = true
        // Snapshots end up in the README; someone's desktop picture shouldn't.
        guard !CommandLine.arguments.contains("--demo-snapshot") else { return nil }
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = NSImage(contentsOf: url),
              let full = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              full.width > 0, full.height > 0
        else { return nil }
        // Backdrops are never larger than a screen; no need to keep 6K around.
        let ratio = min(1, 2880 / CGFloat(max(full.width, full.height)))
        let size = CGSize(width: CGFloat(full.width) * ratio, height: CGFloat(full.height) * ratio)
        cached = PixelImage(size: size, scale: 1, opaque: true) { context in
            context.interpolationQuality = .high
            AnnotationRenderer.draw(full, in: CGRect(origin: .zero, size: size), context: context)
        }.cgImage
        return cached
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Parses "#RRGGBB".
    convenience init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
