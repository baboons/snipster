import AppKit
import Carbon.HIToolbox

enum SelectionMode {
    /// Drag out a rectangle.
    case area
    /// Click a window to take exactly its bounds.
    case window
}

enum SelectionResult {
    case region(frame: DisplayFrame, rect: PixelRect)
    /// A whole window was picked; `rect` is where it sits in the frame.
    case window(frame: DisplayFrame, rect: PixelRect, windowID: CGWindowID)
    case color(PixelColor)
    case cancelled
}

/// A window that was on screen when the capture was taken, in AppKit screen
/// coordinates, front to back.
struct WindowCandidate {
    let windowID: CGWindowID
    let frame: CGRect

    @MainActor
    static func onScreen() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        // CoreGraphics measures from the top of the primary display, AppKit from its bottom.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return WindowCandidate(windowID: number, frame: CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                                                   width: bounds.width, height: bounds.height))
        }
    }
}

/// One selection interaction across every display: shows each frozen frame
/// in a borderless window on its screen and reports what the user picked.
@MainActor
final class SelectionSession {
    private(set) var mode: SelectionMode
    let candidates: [WindowCandidate]
    let showsLoupe: Bool
    /// Set by the snapshot harness: keeps the overlay behind other windows
    /// and away from keyboard focus so rendering it doesn't disturb anyone.
    var isBackgroundDemo = false
    private var frames: [DisplayFrame]
    private var windows: [OverlayWindow] = []
    private var completion: ((SelectionResult) -> Void)?
    private var keyObserver: NSObjectProtocol?

    init(frames: [DisplayFrame], mode: SelectionMode, candidates: [WindowCandidate], showsLoupe: Bool,
         completion: @escaping (SelectionResult) -> Void) {
        self.frames = frames
        self.mode = mode
        self.candidates = candidates
        self.showsLoupe = showsLoupe
        self.completion = completion
    }

    var views: [SelectionView] { windows.map(\.selectionView) }

    /// Overlay windows waiting for the next session, one per display.
    /// Building a full-screen window with its layers takes longer than the
    /// screenshot itself, so it happens ahead of time.
    private static var pool: [CGDirectDisplayID: OverlayWindow] = [:]

    /// Call at launch and whenever the display arrangement changes.
    static func prewarm() {
        var fresh: [CGDirectDisplayID: OverlayWindow] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let window = pool[id] ?? OverlayWindow(screenFrame: screen.frame)
            window.setFrame(screen.frame, display: false)
            fresh[id] = window
        }
        pool = fresh
    }

    private func window(showing frame: DisplayFrame) -> OverlayWindow {
        let window = SelectionSession.pool.removeValue(forKey: frame.displayID)
            ?? OverlayWindow(screenFrame: frame.screenFrame)
        window.setFrame(frame.screenFrame, display: false)
        window.selectionView.attach(frame, session: self)
        return window
    }

    /// Freezes one more display. Frames arrive one at a time, the display
    /// under the pointer first, so the overlay never waits for all of them.
    func add(_ frame: DisplayFrame) {
        guard completion != nil else { return }
        let window = window(showing: frame)
        frames.append(frame)
        windows.append(window)
        let mouse = NSEvent.mouseLocation
        if window.frame.contains(mouse) { window.selectionView.pointerMoved(toScreenPoint: mouse) }
        window.level = .screenSaver
        window.orderFrontRegardless()
    }

    func begin() {
        windows = frames.map(window(showing:))
        if isBackgroundDemo {
            for window in windows {
                window.level = .normal
                window.orderBack(nil)
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        let active = windows.first { $0.frame.contains(mouse) } ?? windows.first
        active?.selectionView.pointerMoved(toScreenPoint: mouse)
        for window in windows {
            window.level = .screenSaver
            window.orderFrontRegardless()
        }

        // Taking keyboard focus costs a few milliseconds; do it once the
        // overlay is already on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.completion != nil else { return }
            active?.makeKey()
            NSCursor.crosshair.set()
            // If the user switches away (Cmd-Tab, Mission Control), don't
            // leave a frozen picture of the screen hanging around.
            self.keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? OverlayWindow, self.windows.contains(window) else { return }
                    DispatchQueue.main.async {
                        if !self.windows.contains(where: \.isKeyWindow) { self.finish(.cancelled) }
                    }
                }
            }
        }
    }

    func toggleMode() {
        mode = mode == .area ? .window : .area
        if mode == .window, !isBackgroundDemo { ScreenCapturer.shared.prepareWindowCapture() }
        for view in views { view.modeChanged() }
    }

    func finish(_ result: SelectionResult) {
        guard let completion else { return }
        self.completion = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        for (window, frame) in zip(windows, frames) {
            window.orderOut(nil)
            window.selectionView.detach()
            SelectionSession.pool[frame.displayID] = window
        }
        windows = []
        completion(result)
    }
}

final class OverlayWindow: NSPanel {
    let selectionView: SelectionView

    init(screenFrame: CGRect) {
        selectionView = SelectionView(frame: CGRect(origin: .zero, size: screenFrame.size))
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screenFrame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = selectionView
        initialFirstResponder = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The frozen picture of one display plus everything drawn over it while
/// selecting. All of it is Core Animation layers updated with implicit
/// animations off, so tracking the pointer never waits on a redraw.
final class SelectionView: NSView {
    /// The frame being shown; nil while the window waits in the pool.
    private var capture: DisplayFrame?
    private weak var session: SelectionSession?
    private var scale: CGFloat = 1
    private var pixelSize: (width: Int, height: Int) = (0, 0)
    private var screenFrame = CGRect.zero

    private let frozenLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let horizontalLine = CALayer()
    private let verticalLine = CALayer()
    private let sizeBadge = BadgeLayer()
    private let hintBadge = BadgeLayer()
    private let loupe = LoupeLayer()

    /// Pointer position in view coordinates (origin bottom-left), nil while it's on another display.
    private var pointer: CGPoint?
    /// Fixed corner of the rectangle being dragged, in pixels from the top-left.
    private var anchor: (x: Int, y: Int)?
    private var selection: PixelRect?
    /// The window under the pointer in window mode, and its part of this
    /// display in view coordinates.
    private var hoveredWindow: (id: CGWindowID, rect: CGRect)?
    private var movingSelection = false
    private var lastDragPixel: (x: Int, y: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        frozenLayer.contentsGravity = .resize
        frozenLayer.magnificationFilter = .nearest
        frozenLayer.minificationFilter = .linear
        root.addSublayer(frozenLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        root.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.6
        borderLayer.shadowRadius = 1.5
        borderLayer.shadowOffset = .zero
        root.addSublayer(borderLayer)

        for line in [horizontalLine, verticalLine] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            line.shadowColor = NSColor.black.cgColor
            line.shadowOpacity = 0.55
            line.shadowRadius = 0.6
            line.shadowOffset = .zero
            line.isHidden = true
            root.addSublayer(line)
        }

        root.addSublayer(sizeBadge)
        sizeBadge.isHidden = true
        root.addSublayer(hintBadge)
        loupe.isHidden = true
        root.addSublayer(loupe)

        layoutLayers()
    }

    /// Shows a freshly captured frame and resets every trace of the last session.
    func attach(_ frame: DisplayFrame, session: SelectionSession) {
        capture = frame
        self.session = session
        scale = frame.scale
        pixelSize = (frame.width, frame.height)
        screenFrame = frame.screenFrame
        pointer = nil
        hoveredWindow = nil
        movingSelection = false
        lastDragPixel = nil
        withoutAnimation {
            frozenLayer.contents = frame.layerContents
            for sublayer in layer?.sublayers ?? [] { sublayer.contentsScale = scale }
            modeChanged()
        }
    }

    /// Lets go of the frame (tens of megabytes) once the session is over.
    func detach() {
        capture = nil
        session = nil
        withoutAnimation { frozenLayer.contents = nil }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        withoutAnimation {
            frozenLayer.frame = bounds
            dimLayer.frame = bounds
            borderLayer.frame = bounds
            refresh()
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Coordinates

    /// The pixel under a view point, clamped to the frame.
    private func pixel(at point: CGPoint) -> (x: Int, y: Int) {
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((bounds.height - point.y) * scale).rounded(.down))
        return (min(max(x, 0), pixelSize.width - 1), min(max(y, 0), pixelSize.height - 1))
    }

    /// The nearest pixel corner to a view point, so rectangles can reach the edges.
    private func corner(at point: CGPoint) -> (x: Int, y: Int) {
        let x = Int((point.x * scale).rounded())
        let y = Int(((bounds.height - point.y) * scale).rounded())
        return (min(max(x, 0), pixelSize.width), min(max(y, 0), pixelSize.height))
    }

    private func viewRect(for rect: PixelRect) -> CGRect {
        CGRect(x: CGFloat(rect.x) / scale, y: bounds.height - CGFloat(rect.y + rect.height) / scale,
               width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale)
    }

    private func viewPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    // MARK: State changes

    func modeChanged() {
        guard let session else { return }
        anchor = nil
        selection = nil
        hintBadge.setText(session.mode == .area
            ? "Drag to capture  ·  Space: window  ·  C: copy colour  ·  Esc: cancel"
            : "Click a window  ·  Space: area  ·  Esc: cancel")
        hintBadge.opacity = 1
        withoutAnimation { refresh() }
    }

    func pointerMoved(toScreenPoint point: CGPoint) {
        pointerMoved(to: viewPoint(fromScreen: point))
    }

    private func pointerMoved(to point: CGPoint) {
        pointer = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        if let anchor, session?.mode == .area {
            let current = corner(at: point)
            if movingSelection, let last = lastDragPixel, var moved = selection {
                // Space held: slide the whole rectangle instead of resizing it.
                moved.x = min(max(moved.x + current.x - last.x, 0), pixelSize.width - moved.width)
                moved.y = min(max(moved.y + current.y - last.y, 0), pixelSize.height - moved.height)
                let dx = moved.x - (selection?.x ?? moved.x)
                let dy = moved.y - (selection?.y ?? moved.y)
                self.anchor = (anchor.x + dx, anchor.y + dy)
                selection = moved
            } else {
                selection = PixelRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                                      width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
            }
            lastDragPixel = current
        }
        if session?.mode == .window {
            let screenPoint = CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY)
            hoveredWindow = session?.candidates.first { $0.frame.contains(screenPoint) }.map { candidate in
                let visible = candidate.frame.intersection(screenFrame)
                return (candidate.windowID, CGRect(origin: viewPoint(fromScreen: visible.origin), size: visible.size))
            }
        }
        withoutAnimation { refresh() }
    }

    private func pointerLeft() {
        guard anchor == nil else { return }
        pointer = nil
        hoveredWindow = nil
        withoutAnimation { refresh() }
    }

    /// Repositions every layer from the current state.
    private func refresh() {
        guard let session else { return }
        let outline = NSColor.white.cgColor
        var hole: CGRect?

        switch session.mode {
        case .area:
            if let selection, anchor != nil {
                hole = viewRect(for: selection)
                borderLayer.strokeColor = outline
                borderLayer.lineWidth = 1
            }
        case .window:
            if let hoveredWindow {
                hole = hoveredWindow.rect
                borderLayer.strokeColor = NSColor.controlAccentColor.cgColor
                borderLayer.lineWidth = 3
            }
        }

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(hole) }
        dimLayer.path = dim
        borderLayer.path = hole.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }

        let dragging = anchor != nil
        let showCrosshair = pointer != nil && session.mode == .area && !dragging
        horizontalLine.isHidden = !showCrosshair
        verticalLine.isHidden = !showCrosshair
        if let pointer, showCrosshair {
            let thickness = 1 / scale
            horizontalLine.frame = CGRect(x: 0, y: pointer.y - thickness / 2, width: bounds.width, height: thickness)
            verticalLine.frame = CGRect(x: pointer.x - thickness / 2, y: 0, width: thickness, height: bounds.height)
        }

        if let selection, dragging, let hole, session.mode == .area {
            sizeBadge.setText("\(selection.width) × \(selection.height)")
            var origin = CGPoint(x: hole.minX, y: hole.maxY + 6)
            if origin.y + sizeBadge.bounds.height > bounds.height - 4 {
                origin.y = hole.maxY - sizeBadge.bounds.height - 6
                origin.x += 6
            }
            origin.x = min(max(origin.x, 4), bounds.width - sizeBadge.bounds.width - 4)
            sizeBadge.frame.origin = origin
            sizeBadge.isHidden = false
        } else {
            sizeBadge.isHidden = true
        }

        hintBadge.frame.origin = CGPoint(x: (bounds.width - hintBadge.bounds.width) / 2,
                                         y: bounds.height - hintBadge.bounds.height - 64)
        hintBadge.isHidden = pointer == nil && !dragging

        if let pointer, capture != nil, session.showsLoupe, session.mode == .area {
            let center = pixel(at: pointer)
            if let capture { loupe.update(frame: capture, x: center.x, y: center.y) }
            let gap: CGFloat = 22
            var origin = CGPoint(x: pointer.x + gap, y: pointer.y - gap - loupe.bounds.height)
            if origin.x + loupe.bounds.width > bounds.width - 4 { origin.x = pointer.x - gap - loupe.bounds.width }
            if origin.y < 4 { origin.y = pointer.y + gap }
            loupe.frame.origin = origin
            loupe.isHidden = false
        } else {
            loupe.isHidden = true
        }
    }

    // MARK: Mouse

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.crosshair.set()
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        pointerLeft()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if session?.mode == .area {
            anchor = corner(at: point)
            lastDragPixel = anchor
            selection = PixelRect(x: anchor!.x, y: anchor!.y, width: 0, height: 0)
            hintBadge.opacity = 0
        }
        pointerMoved(to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
        guard let session, let capture else { return }
        switch session.mode {
        case .window:
            if let hoveredWindow {
                let screenRect = hoveredWindow.rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
                session.finish(.window(frame: capture, rect: capture.pixelRect(forScreenRect: screenRect),
                                       windowID: hoveredWindow.id))
            }
        case .area:
            let picked = selection
            anchor = nil
            lastDragPixel = nil
            movingSelection = false
            selection = nil
            if let picked, picked.width >= 2, picked.height >= 2 {
                session.finish(.region(frame: capture, rect: picked))
            } else {
                // A click without a drag: stay in selection mode.
                hintBadge.opacity = 1
                withoutAnimation { refresh() }
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        session?.finish(.cancelled)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        switch Int(event.keyCode) {
        case kVK_Escape:
            session.finish(.cancelled)
        case kVK_Space:
            guard !event.isARepeat else { return }
            if anchor != nil {
                movingSelection = true
            } else {
                session.toggleMode()
                if let pointer { pointerMoved(to: pointer) }
            }
        case kVK_ANSI_C:
            if let pointer, anchor == nil {
                let center = pixel(at: pointer)
                if let color = capture?.color(atX: center.x, y: center.y) { session.finish(.color(color)) }
            }
        case kVK_LeftArrow: nudgePointer(dx: -1, dy: 0, large: event.modifierFlags.contains(.shift))
        case kVK_RightArrow: nudgePointer(dx: 1, dy: 0, large: event.modifierFlags.contains(.shift))
        case kVK_UpArrow: nudgePointer(dx: 0, dy: 1, large: event.modifierFlags.contains(.shift))
        case kVK_DownArrow: nudgePointer(dx: 0, dy: -1, large: event.modifierFlags.contains(.shift))
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { movingSelection = false }
    }

    /// Moves the real pointer by one pixel (ten with Shift) for precise placement.
    private func nudgePointer(dx: CGFloat, dy: CGFloat, large: Bool) {
        guard let pointer else { return }
        let step = (large ? 10 : 1) / scale
        let target = CGPoint(x: min(max(pointer.x + dx * step, 0), bounds.width - 1 / scale),
                             y: min(max(pointer.y + dy * step, 1 / scale), bounds.height))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = CGPoint(x: target.x + screenFrame.minX, y: target.y + screenFrame.minY)
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y))
        // Warping suppresses mouse movement briefly unless re-associated.
        CGAssociateMouseAndMouseCursorPosition(1)
        pointerMoved(to: target)
    }
}

/// A rounded dark pill with a line of text.
private final class BadgeLayer: CALayer {
    private let label = CATextLayer()
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    override init() {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        cornerRadius = 6
        label.font = BadgeLayer.font
        label.fontSize = BadgeLayer.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        addSublayer(label)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var contentsScale: CGFloat {
        didSet { label.contentsScale = contentsScale }
    }

    func setText(_ text: String) {
        guard (label.string as? String) != text else { return }
        label.string = text
        let size = (text as NSString).size(withAttributes: [.font: BadgeLayer.font])
        let padding = CGSize(width: 9, height: 4)
        bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + padding.width * 2, height: ceil(size.height) + padding.height * 2)
        anchorPoint = .zero
        label.frame = CGRect(x: padding.width, y: padding.height, width: ceil(size.width), height: ceil(size.height))
    }
}

/// The magnifier that follows the pointer: an enlarged grid of the pixels
/// around it, with the centre pixel's colour and position underneath.
private final class LoupeLayer: CALayer {
    /// Pixels shown across (odd, so one pixel sits dead centre).
    private static let span = 15
    private static let cell: CGFloat = 8
    private static let side = CGFloat(span) * cell
    private static let footer: CGFloat = 36
    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

    private let zoom = CALayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let swatch = CALayer()
    private let hexLabel = CATextLayer()
    private let positionLabel = CATextLayer()

    override init() {
        super.init()
        let side = LoupeLayer.side
        anchorPoint = .zero
        bounds = CGRect(x: 0, y: 0, width: side, height: side + LoupeLayer.footer)
        backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        cornerRadius = 9
        borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        borderWidth = 1
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 8
        shadowOffset = CGSize(width: 0, height: -2)

        let clip = CALayer()
        clip.frame = bounds
        clip.cornerRadius = cornerRadius
        clip.masksToBounds = true
        addSublayer(clip)

        zoom.frame = CGRect(x: 0, y: LoupeLayer.footer, width: side, height: side)
        zoom.magnificationFilter = .nearest
        zoom.contentsGravity = .resize
        clip.addSublayer(zoom)

        let lines = CGMutablePath()
        for i in 1..<LoupeLayer.span {
            let offset = CGFloat(i) * LoupeLayer.cell
            lines.move(to: CGPoint(x: offset, y: 0))
            lines.addLine(to: CGPoint(x: offset, y: side))
            lines.move(to: CGPoint(x: 0, y: offset))
            lines.addLine(to: CGPoint(x: side, y: offset))
        }
        grid.frame = zoom.frame
        grid.path = lines
        grid.strokeColor = NSColor.black.withAlphaComponent(0.12).cgColor
        grid.lineWidth = 0.5
        clip.addSublayer(grid)

        let middle = CGFloat(LoupeLayer.span / 2) * LoupeLayer.cell
        center.frame = zoom.frame
        center.path = CGPath(rect: CGRect(x: middle, y: middle, width: LoupeLayer.cell, height: LoupeLayer.cell).insetBy(dx: -0.5, dy: -0.5), transform: nil)
        center.fillColor = nil
        center.strokeColor = NSColor.white.cgColor
        center.lineWidth = 1
        center.shadowColor = NSColor.black.cgColor
        center.shadowOpacity = 0.9
        center.shadowRadius = 0.8
        center.shadowOffset = .zero
        clip.addSublayer(center)

        swatch.frame = CGRect(x: 9, y: 11, width: 14, height: 14)
        swatch.cornerRadius = 3
        swatch.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        swatch.borderWidth = 0.5
        clip.addSublayer(swatch)

        for (label, y) in [(hexLabel, CGFloat(18)), (positionLabel, CGFloat(4))] {
            label.font = LoupeLayer.font
            label.fontSize = LoupeLayer.font.pointSize
            label.frame = CGRect(x: 30, y: y, width: side - 34, height: 14)
            label.alignmentMode = .left
            clip.addSublayer(label)
        }
        hexLabel.foregroundColor = NSColor.white.cgColor
        positionLabel.foregroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var contentsScale: CGFloat {
        didSet {
            for layer in [grid, center, hexLabel, positionLabel] as [CALayer] { layer.contentsScale = contentsScale }
        }
    }

    func update(frame: DisplayFrame, x: Int, y: Int) {
        let span = LoupeLayer.span
        let half = span / 2
        // A fresh 15x15 bitmap per move is cheaper than it sounds (a few
        // hundred bytes) and sidesteps any ambiguity about layer geometry.
        let tile = PixelImage(width: span, height: span, scale: 1, opaque: true) { bytes, stride in
            let pixels = bytes.assumingMemoryBound(to: UInt8.self)
            for row in 0..<span {
                for column in 0..<span {
                    let color = frame.color(atX: x - half + column, y: y - half + row)
                    let offset = row * stride + column * 4
                    pixels[offset] = color?.blue ?? 0
                    pixels[offset + 1] = color?.green ?? 0
                    pixels[offset + 2] = color?.red ?? 0
                    pixels[offset + 3] = 255
                }
            }
        }
        zoom.contents = tile.cgImage
        if let color = frame.color(atX: x, y: y) {
            swatch.backgroundColor = color.cgColor
            hexLabel.string = color.hex
        }
        positionLabel.string = "\(x), \(y)"
    }
}
