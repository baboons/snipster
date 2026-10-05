import AppKit
import CSnipsterCore

/// A bitmap in the one format the whole app speaks: premultiplied BGRA8 in
/// sRGB. The pixels are never mutated after creation, so it can be shared
/// freely between threads, undo states and windows.
final class PixelImage: @unchecked Sendable {
    /// Owns the allocation. CGImages made from a `PixelImage` retain this
    /// rather than the image itself, so cached CGImages don't form a cycle.
    private final class Storage {
        let bytes: UnsafeMutableRawPointer
        init(byteCount: Int) {
            bytes = UnsafeMutableRawPointer.allocate(byteCount: max(byteCount, 1), alignment: 64)
        }
        deinit { bytes.deallocate() }
    }

    let width: Int
    let height: Int
    let stride: Int
    /// Pixels per point: 2 for captures from a Retina display.
    let scale: CGFloat
    /// True when every pixel is fully opaque (anything cropped from a display).
    let opaque: Bool

    private let storage: Storage
    private let cgImageLock = NSLock()
    private var cachedCGImage: CGImage?

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var bytes: UnsafeRawPointer { UnsafeRawPointer(storage.bytes) }
    var pixelSize: CGSize { CGSize(width: width, height: height) }
    /// Size in points, which is how the image is laid out on screen.
    var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }

    /// Allocates an image and lets `fill` write its pixels.
    init(width: Int, height: Int, scale: CGFloat, opaque: Bool,
         fill: (_ bytes: UnsafeMutableRawPointer, _ stride: Int) -> Void) {
        self.width = width
        self.height = height
        self.stride = width * 4
        self.scale = scale
        self.opaque = opaque
        storage = Storage(byteCount: width * 4 * height)
        fill(storage.bytes, stride)
    }

    /// Copies `rect` (in pixels) out of a foreign BGRA buffer.
    convenience init(copying source: UnsafeRawPointer, stride sourceStride: Int, rect: PixelRect,
                     scale: CGFloat, opaque: Bool) {
        self.init(width: rect.width, height: rect.height, scale: scale, opaque: opaque) { bytes, stride in
            for row in 0..<rect.height {
                let from = source + (rect.y + row) * sourceStride + rect.x * 4
                (bytes + row * stride).copyMemory(from: from, byteCount: rect.width * 4)
            }
        }
    }

    /// Copies a whole BGRA pixel buffer, as ScreenCaptureKit delivers them.
    convenience init?(pixelBuffer: CVPixelBuffer, scale: CGFloat, opaque: Bool) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rect = PixelRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard !rect.isEmpty else { return nil }
        self.init(copying: base, stride: CVPixelBufferGetBytesPerRow(pixelBuffer), rect: rect, scale: scale, opaque: opaque)
    }

    /// Rasterises with CoreGraphics. The context is in points with a top-left
    /// origin, matching the flipped views the editor draws in.
    convenience init(size: CGSize, scale: CGFloat, opaque: Bool, draw: (CGContext) -> Void) {
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        self.init(width: width, height: height, scale: scale, opaque: opaque) { bytes, stride in
            memset(bytes, 0, stride * height)
            guard let context = CGContext(
                data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: PixelImage.colorSpace, bitmapInfo: PixelImage.bitmapInfo(opaque: false).rawValue)
            else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            draw(context)
        }
    }

    /// Converts any CGImage (a decoded file, a window capture) into our format.
    convenience init(cgImage: CGImage, scale: CGFloat) {
        let alpha = cgImage.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        self.init(width: cgImage.width, height: cgImage.height, scale: scale, opaque: opaque) { bytes, stride in
            memset(bytes, 0, stride * cgImage.height)
            let context = CGContext(
                data: bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: stride, space: PixelImage.colorSpace,
                bitmapInfo: PixelImage.bitmapInfo(opaque: false).rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
    }

    private static func bitmapInfo(opaque: Bool) -> CGBitmapInfo {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        return CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// A CGImage that shares this image's pixels (no copy).
    var cgImage: CGImage {
        cgImageLock.lock()
        defer { cgImageLock.unlock() }
        if let cachedCGImage { return cachedCGImage }
        let info = Unmanaged.passRetained(storage).toOpaque()
        let provider = CGDataProvider(
            dataInfo: info, data: storage.bytes, size: stride * height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<Storage>.fromOpaque(info).release() }
            })!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: PixelImage.colorSpace, bitmapInfo: PixelImage.bitmapInfo(opaque: opaque),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        cachedCGImage = image
        return image
    }

    var nsImage: NSImage { NSImage(cgImage: cgImage, size: size) }

    func cropped(to rect: PixelRect) -> PixelImage {
        let rect = rect.clamped(width: width, height: height)
        return PixelImage(copying: bytes, stride: stride, rect: rect, scale: scale, opaque: opaque)
    }

    /// Returns a copy of `rect` with a redaction effect applied by the Rust core.
    func redacted(_ rect: PixelRect, effect: RedactionEffect) -> PixelImage {
        let rect = rect.clamped(width: width, height: height)
        return PixelImage(width: rect.width, height: rect.height, scale: scale, opaque: opaque) { bytes, stride in
            for row in 0..<rect.height {
                let from = self.bytes + (rect.y + row) * self.stride + rect.x * 4
                (bytes + row * stride).copyMemory(from: from, byteCount: rect.width * 4)
            }
            let pixels = bytes.assumingMemoryBound(to: UInt8.self)
            let all = SnipRect(x: 0, y: 0, w: rect.width, h: rect.height)
            switch effect {
            case .pixelate(let block):
                snip_pixelate(pixels, rect.width, rect.height, stride, all, max(2, block))
            case .blur(let radius):
                snip_blur(pixels, rect.width, rect.height, stride, all, max(1, radius))
            }
        }
    }

    /// PNG-encodes on all cores. `level` is the zlib level: low for the
    /// clipboard where latency matters, higher for files.
    func pngData(level: Int = 6) -> Data {
        var flags = UInt32(SNIP_PNG_ADAPTIVE)
        if opaque { flags |= UInt32(SNIP_PNG_OPAQUE) }
        let dpi = UInt32((72 * scale).rounded())
        let buffer = snip_encode_png(
            bytes.assumingMemoryBound(to: UInt8.self), width, height, stride,
            SnipRect(x: 0, y: 0, w: width, h: height), flags, UInt32(level), dpi == 72 ? 0 : dpi)
        return Data(rustBuffer: buffer)
    }
}

enum RedactionEffect: Hashable, Sendable {
    case pixelate(block: Int)
    case blur(radius: Int)
}

/// An integer rectangle in image pixels, origin top-left.
struct PixelRect: Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The pixels a rect in points covers, rounded outwards to whole pixels.
    init(_ rect: CGRect, scale: CGFloat) {
        let minX = Int((rect.minX * scale).rounded(.down))
        let minY = Int((rect.minY * scale).rounded(.down))
        let maxX = Int((rect.maxX * scale).rounded(.up))
        let maxY = Int((rect.maxY * scale).rounded(.up))
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func clamped(width maxWidth: Int, height maxHeight: Int) -> PixelRect {
        let x0 = min(max(x, 0), maxWidth)
        let y0 = min(max(y, 0), maxHeight)
        let x1 = min(max(x + width, x0), maxWidth)
        let y1 = min(max(y + height, y0), maxHeight)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func cgRect(scale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale,
               width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }
}

struct PixelColor: Hashable, Sendable {
    var blue: UInt8
    var green: UInt8
    var red: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

extension Data {
    /// Wraps a buffer from the Rust core without copying; it is handed back
    /// to Rust when the `Data` is released.
    init(rustBuffer buffer: SnipBuffer) {
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            snip_buffer_free(buffer)
            self.init()
            return
        }
        self.init(bytesNoCopy: pointer, count: buffer.len, deallocator: .custom { _, _ in
            snip_buffer_free(buffer)
        })
    }
}
