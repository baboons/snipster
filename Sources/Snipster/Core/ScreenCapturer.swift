import AppKit
import CoreMedia
import ScreenCaptureKit

/// One display, frozen at the moment of capture. The pixels stay in the
/// IOSurface ScreenCaptureKit delivered them in: the overlay shows that
/// surface directly and crops read straight from it, so nothing is copied
/// until the user has picked a region.
final class DisplayFrame {
    let displayID: CGDirectDisplayID
    /// The display's rectangle in AppKit screen coordinates (origin bottom-left).
    let screenFrame: CGRect
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int
    let stride: Int
    /// Pixels per point.
    let scale: CGFloat
    private let base: UnsafeRawPointer

    init?(displayID: CGDirectDisplayID, screenFrame: CGRect, pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.pixelBuffer = pixelBuffer
        self.base = UnsafeRawPointer(base)
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        scale = screenFrame.width > 0 ? CGFloat(width) / screenFrame.width : 1
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    /// Something a CALayer can show as `contents` without copying pixels.
    var layerContents: Any? {
        CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
    }

    var pixelBounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    func color(atX x: Int, y: Int) -> PixelColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        return PixelColor(blue: px[0], green: px[1], red: px[2])
    }

    func image(cropping rect: PixelRect) -> PixelImage? {
        let rect = rect.clamped(width: width, height: height)
        guard !rect.isEmpty else { return nil }
        return PixelImage(copying: base, stride: stride, rect: rect, scale: scale, opaque: true)
    }

    /// Converts a rect in AppKit screen coordinates to this frame's pixels.
    func pixelRect(forScreenRect rect: CGRect) -> PixelRect {
        let local = CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        return PixelRect(local, scale: scale).clamped(width: width, height: height)
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Snipster needs the Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch."
        case .noDisplays:
            "No displays are available to capture."
        case .failed(let reason):
            "Capture failed: \(reason)"
        }
    }
}

/// Grabs displays through ScreenCaptureKit.
///
/// Looking up shareable content is by far the slowest part of a screenshot,
/// so the per-display filters and configurations are built ahead of time and
/// reused; a capture is then a single round trip to the window server.
@MainActor
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private struct Target {
        let displayID: CGDirectDisplayID
        let screenFrame: CGRect
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private var targets: [Target] = []
    private var preparing: Task<Void, Error>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system permission prompt the first time it is called.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    private func invalidate() {
        targets = []
        preparing = nil
        warmUp()
    }

    /// Builds the capture targets in the background so the first hotkey press is fast.
    func warmUp() {
        guard ScreenCapturer.hasPermission else { return }
        Task { try? await prepare() }
    }

    private func prepare() async throws {
        if !targets.isEmpty { return }
        if let preparing { return try await preparing.value }
        let task = Task { try await self.buildTargets() }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func buildTargets() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCapturer.hasPermission ? CaptureError.failed(error.localizedDescription) : CaptureError.permissionDenied
        }
        var screens: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { screens[id] = screen }
        }
        targets = content.displays.compactMap { display in
            guard let screen = screens[display.displayID] else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * scale).rounded())
            configuration.height = Int((filter.contentRect.height * scale).rounded())
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false
            configuration.captureResolution = .best
            return Target(displayID: display.displayID, screenFrame: screen.frame,
                          filter: filter, configuration: configuration)
        }
        if targets.isEmpty { throw CaptureError.noDisplays }
    }

    /// Captures displays, delivering each frame as soon as it exists.
    ///
    /// The window server answers screenshot requests one after another, so
    /// asking for everything at once would make the display the user is
    /// looking at wait behind the others at random. Instead `first` (the one
    /// under the pointer) is requested alone, and the rest follow once it has
    /// landed; with `onlyFirst` they are skipped entirely.
    ///
    /// When the targets are already prepared, the first request is on its way
    /// before this returns, so the caller can get on with other setup while
    /// it is in flight. Both callbacks run later, on the main thread;
    /// `completion` gets an error only if no frame could be delivered.
    func captureDisplays(startingWith first: CGDirectDisplayID?, onlyFirst: Bool = false,
                         onFrame: @escaping @MainActor (DisplayFrame) -> Void,
                         completion: @escaping @MainActor (CaptureError?) -> Void) {
        let run = CaptureRun(first: first, onlyFirst: onlyFirst, onFrame: onFrame, completion: completion)
        if targets.isEmpty {
            rebuildTargets(thenStart: run)
        } else {
            start(run, retryingStaleTargets: true)
        }
    }

    /// Captures every display and waits for all of them.
    func captureDisplays() async throws -> [DisplayFrame] {
        try await withCheckedThrowingContinuation { continuation in
            var frames: [DisplayFrame] = []
            captureDisplays(startingWith: nil, onFrame: { frames.append($0) }, completion: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: frames)
                }
            })
        }
    }

    private static func captureError(from error: Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        return hasPermission ? .failed(error.localizedDescription) : .permissionDenied
    }

    /// One call to `captureDisplays`. Only ever touched on the main thread;
    /// the ScreenCaptureKit completion handlers just carry it back there.
    private final class CaptureRun: @unchecked Sendable {
        let first: CGDirectDisplayID?
        let onlyFirst: Bool
        let onFrame: @MainActor (DisplayFrame) -> Void
        let completion: @MainActor (CaptureError?) -> Void
        var delivered = 0
        var outstanding = 0
        var failure: Error?

        init(first: CGDirectDisplayID?, onlyFirst: Bool, onFrame: @escaping @MainActor (DisplayFrame) -> Void,
             completion: @escaping @MainActor (CaptureError?) -> Void) {
            self.first = first
            self.onlyFirst = onlyFirst
            self.onFrame = onFrame
            self.completion = completion
        }
    }

    private func rebuildTargets(thenStart run: CaptureRun) {
        targets = []
        Task {
            do {
                try await prepare()
                start(run, retryingStaleTargets: false)
            } catch {
                run.completion(ScreenCapturer.captureError(from: error))
            }
        }
    }

    private func start(_ run: CaptureRun, retryingStaleTargets: Bool) {
        var queue = targets
        if let index = queue.firstIndex(where: { $0.displayID == run.first }) {
            queue.insert(queue.remove(at: index), at: 0)
        }
        guard let head = queue.first else {
            run.completion(.noDisplays)
            return
        }
        let rest = run.onlyFirst ? [] : Array(queue.dropFirst())
        request(head, for: run) { [self] succeeded in
            if !succeeded, retryingStaleTargets {
                // Cached filters go stale when displays sleep or get rearranged
                // without a notification; rebuild once and start over.
                run.failure = nil
                rebuildTargets(thenStart: run)
                return
            }
            if rest.isEmpty {
                finish(run)
            } else {
                for target in rest {
                    request(target, for: run) { [self] _ in
                        if run.outstanding == 0 { finish(run) }
                    }
                }
            }
        }
    }

    /// Asks for one display; `done` reports whether a frame was delivered.
    private func request(_ target: Target, for run: CaptureRun, done: @escaping @MainActor (Bool) -> Void) {
        run.outstanding += 1
        SCScreenshotManager.captureSampleBuffer(contentFilter: target.filter, configuration: target.configuration) { sample, error in
            let grabbed = sample?.imageBuffer.map(GrabbedBuffer.init(pixelBuffer:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    run.outstanding -= 1
                    let frame = grabbed.flatMap {
                        DisplayFrame(displayID: target.displayID, screenFrame: target.screenFrame, pixelBuffer: $0.pixelBuffer)
                    }
                    if let frame {
                        run.delivered += 1
                        run.onFrame(frame)
                    } else if run.failure == nil {
                        run.failure = error ?? CaptureError.failed("the window server returned an empty frame")
                    }
                    done(frame != nil)
                }
            }
        }
    }

    private func finish(_ run: CaptureRun) {
        if run.delivered > 0 {
            run.completion(nil)
        } else {
            run.completion(run.failure.map(ScreenCapturer.captureError(from:)) ?? .noDisplays)
        }
    }

    /// Captures a rectangle of one display, in AppKit screen coordinates.
    /// Used for the repeated grabs of a scrolling capture.
    func captureRegion(_ screenRect: CGRect, displayID: CGDirectDisplayID) async throws -> PixelImage {
        try await prepare()
        guard let target = targets.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplays
        }
        let scale = CGFloat(target.filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        // sourceRect is in the display's own points with a top-left origin.
        let local = CGRect(x: screenRect.minX - target.screenFrame.minX,
                           y: target.screenFrame.maxY - screenRect.maxY,
                           width: screenRect.width, height: screenRect.height)
        configuration.sourceRect = local
        configuration.width = Int((local.width * scale).rounded())
        configuration.height = Int((local.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.captureResolution = .best
        let request = GrabRequest(filter: regionFilter ?? target.filter, configuration: configuration)
        let buffer = try await request.grab()
        guard let frame = DisplayFrame(displayID: displayID, screenFrame: screenRect, pixelBuffer: buffer.pixelBuffer),
              let image = frame.image(cropping: frame.pixelBounds)
        else { throw CaptureError.failed("the window server returned an empty frame") }
        return image
    }

    private var regionFilter: SCContentFilter?
    private var windowLookup: Task<WindowList, Never>?

    private struct WindowList: @unchecked Sendable {
        let windows: [SCWindow]
    }

    /// Starts looking up the windows on screen, so that a following
    /// `captureWindow` doesn't have to wait for it. Call when window
    /// selection begins.
    func prepareWindowCapture() {
        windowLookup = Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return WindowList(windows: content?.windows ?? [])
        }
    }

    /// Captures one window on its own: its real outline (rounded corners come
    /// out transparent), without its shadow and without anything overlapping
    /// it. Returns nil if the window can't be captured this way.
    func captureWindow(_ windowID: CGWindowID) async -> PixelImage? {
        if windowLookup == nil { prepareWindowCapture() }
        let list = await windowLookup?.value
        windowLookup = nil
        guard let window = list?.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        guard configuration.width > 0, configuration.height > 0,
              let buffer = try? await GrabRequest(filter: filter, configuration: configuration).grab()
        else { return nil }
        return PixelImage(pixelBuffer: buffer.pixelBuffer, scale: scale, opaque: false)
    }

    /// Prepares a filter for `captureRegion` that leaves the given windows
    /// (the scrolling capture's own outline and controls) out of the picture.
    func prepareRegionCapture(displayID: CGDirectDisplayID, hiding windowIDs: [CGWindowID]) async {
        regionFilter = nil
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return }
        let hidden = content.windows.filter { windowIDs.contains($0.windowID) }
        regionFilter = SCContentFilter(display: display, excludingWindows: hidden)
    }

    func endRegionCapture() {
        regionFilter = nil
    }
}

/// One screenshot request. ScreenCaptureKit's filter and configuration
/// objects are immutable once built, and the pixel buffer it returns is ours
/// alone, so both are safe to hand across tasks.
private struct GrabRequest: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration

    func grab() async throws -> GrabbedBuffer {
        let sample = try await SCScreenshotManager.captureSampleBuffer(
            contentFilter: filter, configuration: configuration)
        guard let buffer = sample.imageBuffer else {
            throw CaptureError.failed("the window server returned an empty frame")
        }
        return GrabbedBuffer(pixelBuffer: buffer)
    }
}

private struct GrabbedBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
