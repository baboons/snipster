import AppKit
import ScreenCaptureKit

/// Development aid: drives the real UI with synthetic input and writes PNGs
/// of the result, so changes can be checked without touching the mouse.
///
///   Snipster --demo-snapshot <scene> out.png
///
/// - `render`, `frames`, `selfcheck`: offscreen, need nothing. `frames`
///   writes one file per decoration style; `selfcheck` asserts the editor's
///   editing operations and text recognition and ignores the path.
/// - `editor`, `decoration`, `overlay`, `pin`, `settings`: photograph their
///   own window, so whatever launched the binary needs Screen Recording access.
/// - `windowshot`: captures the frontmost window on its own and reports how
///   much of it is transparent.
/// - `live`, `scroll`, `activation`: run the real capture flows on the real
///   displays for a moment. Pass `-copyAfterCapture NO -openEditorAfterCapture NO`
///   to keep them from touching the clipboard or opening windows.
@MainActor
enum DemoSnapshot {
    private static var retained: [AnyObject] = []

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-snapshot"), index + 2 < args.count else { return false }
        let scene = args[index + 1]
        let out = URL(fileURLWithPath: args[index + 2])
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        Task {
            do {
                switch scene {
                case "editor": try await editor(to: out)
                case "overlay": try await overlay(to: out)
                case "pin": try await pin(to: out)
                case "settings": try await settings(to: out)
                case "render": try render(to: out)
                case "frames": try frames(to: out)
                case "statusicon": try statusIcon(to: out)
                case "decoration": try await decoration(to: out)
                case "windowshot": try await windowshot(to: out)
                case "selfcheck":
                    try selfcheck()
                    let text = await TextRecognizer.recognize(sampleScreenshot())
                    guard text.contains("Quarterly report"), text.contains("billing@example.com") else {
                        throw CaptureError.failed("selfcheck: text recognition returned \(text.debugDescription)")
                    }
                    print("ok  text recognition reads the sample\nselfcheck passed")
                case "live": try await live(to: out)
                case "activation": try await activation()
                case "scroll": try await scroll(to: out)
                default: throw CaptureError.failed("unknown scene \(scene)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        return true
    }

    // MARK: Sample content

    /// A made-up app window to annotate: no real screen content involved.
    static func sampleScreenshot(size: CGSize = CGSize(width: 760, height: 460)) -> PixelImage {
        PixelImage(size: size, scale: 2, opaque: true) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.restoreGraphicsState() }

            let bounds = CGRect(origin: .zero, size: size)
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.22, blue: 0.48, alpha: 1),
                                NSColor(srgbRed: 0.55, green: 0.27, blue: 0.62, alpha: 1)])?
                .draw(in: bounds, angle: 55)

            let window = bounds.insetBy(dx: 48, dy: 40)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: window, xRadius: 12, yRadius: 12).fill()
            NSColor(white: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 40),
                         xRadius: 12, yRadius: 12).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: window.minX + 16 + CGFloat(i) * 20, y: window.minY + 14, width: 12, height: 12)).fill()
            }
            func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
                NSAttributedString(string: string, attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                ]).draw(at: CGPoint(x: window.minX + x, y: window.minY + y))
            }
            text("Quarterly report", 28, 62, size: 26, weight: .bold)
            text("Revenue grew 18% over the previous quarter.", 28, 104, size: 14, color: NSColor(white: 0.25, alpha: 1))
            text("API key: sk-live-4f9a27c1d0b8e6", 28, 132, size: 14, color: NSColor(white: 0.25, alpha: 1))
            text("Contact: billing@example.com", 28, 158, size: 14, color: NSColor(white: 0.25, alpha: 1))

            let bars: [CGFloat] = [0.35, 0.5, 0.42, 0.7, 0.62, 0.9]
            for (i, value) in bars.enumerated() {
                let height = 130 * value
                NSColor(srgbRed: 0.24, green: 0.47, blue: 0.96, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: window.minX + 40 + CGFloat(i) * 46, y: window.maxY - 36 - height,
                                                 width: 30, height: height), xRadius: 4, yRadius: 4).fill()
            }
            NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: window.maxX - 190, y: window.maxY - 76, width: 150, height: 40),
                         xRadius: 9, yRadius: 9).fill()
            text("Export PDF", window.width - 157, window.height - 66, size: 15, weight: .semibold, color: .white)
        }
    }

    // MARK: Synthetic input

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private static func drag(in view: NSView, from start: CGPoint, to end: CGPoint, via: [CGPoint] = [], release: Bool = true) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: view))
        for point in via + [end] { view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, in: view)) }
        if release { view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, in: view)) }
    }

    private static func click(in view: NSView, at point: CGPoint) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: view))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: view))
    }

    /// Draws one of everything on the sample screenshot through the real tools.
    private static func annotate(_ controller: EditorWindowController) {
        let canvas = controller.canvas
        controller.select(.pixelate)
        drag(in: canvas, from: CGPoint(x: 128, y: 170), to: CGPoint(x: 296, y: 193))
        controller.select(.highlighter)
        drag(in: canvas, from: CGPoint(x: 74, y: 142), to: CGPoint(x: 232, y: 162))
        controller.select(.blur)
        drag(in: canvas, from: CGPoint(x: 132, y: 197), to: CGPoint(x: 276, y: 219))
        controller.select(.rectangle)
        drag(in: canvas, from: CGPoint(x: 512, y: 338), to: CGPoint(x: 680, y: 392))
        controller.select(.arrow)
        drag(in: canvas, from: CGPoint(x: 430, y: 250), to: CGPoint(x: 512, y: 334))
        controller.select(.text)
        click(in: canvas, at: CGPoint(x: 352, y: 214))
        if let editor = canvas.subviews.compactMap({ $0 as? InlineTextEditor }).first {
            editor.insertText("Ship this", replacementRange: NSRange(location: 0, length: 0))
        }
        canvas.commitText()
        controller.pick(Palette.colors[4])
        controller.select(.ellipse)
        drag(in: canvas, from: CGPoint(x: 280, y: 268), to: CGPoint(x: 352, y: 408))
        controller.select(.line)
        drag(in: canvas, from: CGPoint(x: 76, y: 100), to: CGPoint(x: 268, y: 100))
        controller.select(.pen)
        drag(in: canvas, from: CGPoint(x: 560, y: 110), to: CGPoint(x: 690, y: 118),
             via: [CGPoint(x: 580, y: 96), CGPoint(x: 600, y: 124), CGPoint(x: 622, y: 98),
                   CGPoint(x: 644, y: 126), CGPoint(x: 668, y: 100)])
        controller.pick(Palette.colors[0])
        controller.select(.counter)
        click(in: canvas, at: CGPoint(x: 98, y: 300))
        click(in: canvas, at: CGPoint(x: 236, y: 252))
        controller.select(.arrow)
    }

    // MARK: Scenes

    private static func render(to out: URL) throws {
        let controller = EditorWindowController(image: sampleScreenshot(), fileURL: nil)
        annotate(controller)
        let image = controller.canvas.renderedImage()
        try image.pngData().write(to: out)
        print("rendered \(image.width)x\(image.height) with \(controller.canvas.state.annotations.count) annotations")
    }

    /// Exercises the editing operations through the same entry points the
    /// mouse and keyboard use, and fails loudly if any of them misbehaves.
    private static func selfcheck() throws {
        func expect(_ condition: Bool, _ what: String) throws {
            if !condition { throw CaptureError.failed("selfcheck: \(what)") }
            print("ok  \(what)")
        }
        let controller = EditorWindowController(image: sampleScreenshot(), fileURL: nil)
        let canvas = controller.canvas
        var annotations: [Annotation] { canvas.state.annotations }

        controller.select(.rectangle)
        drag(in: canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 220, y: 180))
        try expect(annotations.count == 1 && annotations[0].shape == .rectangle(CGRect(x: 100, y: 100, width: 120, height: 80)),
                   "dragging with the rectangle tool adds a rectangle")
        try expect(canvas.selectedAnnotation?.id == annotations[0].id, "a new shape is selected")

        // Bottom-right handle, dragged past the top-left corner: the rectangle flips.
        drag(in: canvas, from: CGPoint(x: 220, y: 180), to: CGPoint(x: 60, y: 70), via: [CGPoint(x: 150, y: 130)])
        try expect(annotations.count == 1 && annotations[0].shape == .rectangle(CGRect(x: 60, y: 70, width: 40, height: 30)),
                   "dragging a handle across the opposite corner flips the shape")

        click(in: canvas, at: CGPoint(x: 300, y: 300))
        try expect(annotations.count == 1 && canvas.selectedAnnotation == nil, "a click without a drag only deselects")

        controller.select(.select)
        drag(in: canvas, from: CGPoint(x: 60, y: 85), to: CGPoint(x: 160, y: 185))
        try expect(annotations[0].shape == .rectangle(CGRect(x: 160, y: 170, width: 40, height: 30)),
                   "the select tool moves a shape by its outline")

        canvas.undo(nil)
        try expect(annotations[0].shape == .rectangle(CGRect(x: 60, y: 70, width: 40, height: 30)), "undo reverts the move")
        canvas.undo(nil)
        canvas.undo(nil)
        try expect(annotations.isEmpty && !canvas.canUndo, "undo walks back to the untouched screenshot")
        canvas.redo(nil)
        canvas.redo(nil)
        canvas.redo(nil)
        try expect(annotations.count == 1 && !canvas.canRedo, "redo restores everything")

        controller.select(.counter)
        click(in: canvas, at: CGPoint(x: 400, y: 100))
        click(in: canvas, at: CGPoint(x: 440, y: 100))
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.shape { return number }
            return nil
        }
        try expect(numbers == [1, 2], "step numbers count up")

        controller.select(.text)
        click(in: canvas, at: CGPoint(x: 300, y: 200))
        let editor = canvas.subviews.compactMap { $0 as? InlineTextEditor }.first
        try expect(editor != nil, "clicking with the text tool opens an inline editor")
        editor?.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        canvas.commitText()
        try expect(annotations.last?.shape == .text(origin: CGPoint(x: 300, y: 200), string: "Hello"), "committing adds the text")
        click(in: canvas, at: CGPoint(x: 600, y: 300))
        canvas.commitText()
        try expect(annotations.count == 4, "an empty text box adds nothing")

        controller.select(.select)
        click(in: canvas, at: CGPoint(x: 400, y: 100))
        canvas.delete(nil)
        try expect(annotations.count == 3 && canvas.selectedAnnotation == nil, "delete removes the selected annotation")

        controller.pick(Palette.colors[4])
        click(in: canvas, at: CGPoint(x: 310, y: 210))
        controller.pick(Palette.colors[3])
        try expect(annotations.last?.color == Palette.colors[3], "picking a colour restyles the selection")

        let before = canvas.state.image
        controller.select(.crop)
        drag(in: canvas, from: CGPoint(x: 50, y: 60), to: CGPoint(x: 450, y: 260))
        try expect(canvas.state.image.width == 800 && canvas.state.image.height == 400, "crop replaces the image")
        try expect(canvas.frame.size == CGSize(width: 400, height: 200), "the canvas follows the cropped size")
        try expect(annotations.contains { $0.shape == .text(origin: CGPoint(x: 250, y: 140), string: "Hello") },
                   "annotations move with the crop")
        try expect(canvas.tool == .select, "the tool returns to select after cropping")
        let rendered = canvas.renderedImage()
        try expect(rendered.width == 800 && rendered.height == 400 && rendered !== canvas.state.image,
                   "rendering burns annotations into a new image")
        canvas.undo(nil)
        try expect(canvas.state.image === before && canvas.frame.size == before.size, "undo restores the uncropped image")

        // A window frame (32 pt title bar) and backdrop with the default 56 pt padding.
        let count = annotations.count
        controller.decorate(sampleDecoration(window: .light, backdrop: .gradient("aurora")))
        try expect(canvas.documentSize == CGSize(width: 760 + 112, height: 460 + 32 + 112) && canvas.frame.size == canvas.documentSize,
                   "a frame and backdrop grow the canvas")
        var wider = canvas.state.decoration
        wider.padding = 80
        controller.decorate(wider)
        controller.select(.rectangle)
        drag(in: canvas, from: CGPoint(x: 80 + 10, y: 80 + 32 + 20), to: CGPoint(x: 80 + 110, y: 80 + 32 + 70))
        // The picture may be shown scaled down now, so allow for rounding.
        var drawn = CGRect.null
        if case .rectangle(let rect)? = annotations.last?.shape { drawn = rect }
        let wanted = CGRect(x: 10, y: 20, width: 100, height: 50)
        try expect(annotations.count == count + 1 && abs(drawn.minX - wanted.minX) < 0.01 && abs(drawn.minY - wanted.minY) < 0.01
                   && abs(drawn.width - wanted.width) < 0.01 && abs(drawn.height - wanted.height) < 0.01,
                   "annotations stay in image coordinates under a decoration")
        let framed = canvas.renderedImage()
        try expect(framed.width == (760 + 160) * 2 && framed.height == (460 + 32 + 160) * 2 && framed.opaque,
                   "the result includes the frame and backdrop")
        canvas.undo(nil)
        canvas.undo(nil)
        try expect(canvas.state.decoration.isEmpty && canvas.documentSize == before.size && annotations.count == count,
                   "decoration tweaks made in a row undo as one step")
        controller.decorate(sampleDecoration(window: .dark, backdrop: .none))
        try expect(!canvas.renderedImage().opaque, "without a backdrop the padding stays transparent")
        var restored = Decoration(dictionary: wider.dictionary)
        restored.title = wider.title
        try expect(restored == wider, "a decoration survives being saved and loaded")
    }

    private static func sampleDecoration(window: Decoration.WindowStyle, backdrop: Decoration.Backdrop) -> Decoration {
        var decoration = Decoration()
        decoration.window = window
        decoration.backdrop = backdrop
        decoration.title = window == .none ? "" : "Quarterly report"
        return decoration
    }

    /// A plain piece of an app (no desktop around it), which is what a frame
    /// and backdrop are for.
    private static func sampleContent() -> PixelImage {
        sampleScreenshot().cropped(to: PixelRect(x: 96, y: 160, width: 1328, height: 680))
    }

    /// The menu bar icon at its real size and enlarged, on a light and a dark bar.
    private static func statusIcon(to out: URL) throws {
        let icon = StatusIcon.image
        let sheet = PixelImage(size: CGSize(width: 260, height: 120), scale: 2, opaque: true) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.restoreGraphicsState() }
            for (index, dark) in [false, true].enumerated() {
                let band = CGRect(x: 0, y: CGFloat(index) * 60, width: 260, height: 60)
                NSColor(white: dark ? 0.16 : 0.92, alpha: 1).setFill()
                band.fill()
                // Template images are tinted by filling through them.
                for (x, side) in [(20.0, 18.0), (70.0, 36.0), (140.0, 54.0)] as [(CGFloat, CGFloat)] {
                    let rect = CGRect(x: x, y: band.midY - side / 2, width: side, height: side)
                    guard let mask = icon.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: [.ctm: AffineTransform(scale: side / 18 * 2)]) else { continue }
                    context.saveGState()
                    context.translateBy(x: rect.minX, y: rect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.clip(to: CGRect(origin: .zero, size: rect.size), mask: mask)
                    context.setFillColor((dark ? NSColor.white : NSColor.black).cgColor)
                    context.fill(CGRect(origin: .zero, size: rect.size))
                    context.restoreGState()
                }
            }
        }
        try sheet.pngData().write(to: out)
    }

    /// The decoration styles, rendered offscreen: `out.<style>.png`.
    private static func frames(to out: URL) throws {
        let styles: [(String, Decoration)] = [
            ("light", sampleDecoration(window: .light, backdrop: .gradient("aurora"))),
            ("dark", sampleDecoration(window: .dark, backdrop: .gradient("ocean"))),
            ("backdrop", sampleDecoration(window: .none, backdrop: .gradient("sunset"))),
            ("solid", sampleDecoration(window: .light, backdrop: .solid(NSColor(hex: 0xF4F4F5)))),
            ("transparent", sampleDecoration(window: .light, backdrop: .none)),
        ]
        for (name, decoration) in styles {
            let controller = EditorWindowController(image: sampleContent(), fileURL: nil, decoration: decoration)
            controller.select(.arrow)
            drag(in: controller.canvas, from: CGPoint(x: 40, y: 60), to: CGPoint(x: 150, y: 150))
            let image = controller.canvas.renderedImage()
            let url = out.deletingPathExtension().appendingPathExtension("\(name).png")
            try image.pngData().write(to: url)
            print("\(name): \(image.width)x\(image.height), opaque \(image.opaque)")
        }
    }

    /// The editor with a decorated screenshot, and the popover that sets it up.
    private static func decoration(to out: URL) async throws {
        let style = sampleDecoration(window: .light, backdrop: .gradient("aurora"))
        let controller = EditorWindowController(image: sampleContent(), fileURL: nil, decoration: style)
        retained.append(controller)
        guard let window = controller.window else { return }
        window.orderBack(nil)
        controller.select(.arrow)
        // View coordinates: the arrow starts out on the backdrop.
        drag(in: controller.canvas, from: CGPoint(x: 30, y: 250), to: CGPoint(x: 150, y: 200))

        func find(_ view: NSView?) -> ToolbarButton? {
            guard let view else { return nil }
            if let button = view as? ToolbarButton, button.toolTip == "Window frame and background" { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        find(window.contentView)?.performClick(nil)
        try await Task.sleep(for: .milliseconds(400))
        guard NSApp.windows.contains(where: { String(describing: type(of: $0)).contains("Popover") }) else {
            throw CaptureError.failed("the decoration popover didn't open")
        }
        // The popover is a child window, so it is part of the editor's picture.
        try await write(window, to: out)
        find(window.contentView)?.performClick(nil)
        try await Task.sleep(for: .milliseconds(400))

        // A window captured on its own keeps its outline: transparent corners
        // in a bare editor, and a shadow that follows them on a backdrop.
        ScreenCapturer.shared.prepareWindowCapture()
        guard let shaped = await ScreenCapturer.shared.captureWindow(CGWindowID(window.windowNumber)) else {
            throw CaptureError.failed("the editor window couldn't be captured on its own")
        }
        print("window capture \(shaped.width)x\(shaped.height), opaque \(shaped.opaque)")
        for (name, style) in [("window", Decoration()), ("windowbackdrop", sampleDecoration(window: .none, backdrop: .solid(NSColor(hex: 0xF4F4F5))))] {
            let editor = EditorWindowController(image: shaped, fileURL: nil, decoration: style)
            retained.append(editor)
            guard let editorWindow = editor.window else { continue }
            editorWindow.orderBack(nil)
            try await write(editorWindow, to: out.deletingPathExtension().appendingPathExtension("\(name).png"))
        }
    }

    /// Captures the frontmost window the way a window capture does and
    /// reports its transparency, to check corners come out clear.
    private static func windowshot(to out: URL) async throws {
        guard ScreenCapturer.hasPermission else { throw CaptureError.permissionDenied }
        guard let candidate = WindowCandidate.onScreen().first else { throw CaptureError.failed("no window on screen") }
        ScreenCapturer.shared.prepareWindowCapture()
        let clock = ContinuousClock.now
        guard let image = await ScreenCapturer.shared.captureWindow(candidate.windowID) else {
            throw CaptureError.failed("the window couldn't be captured on its own")
        }
        var clear = 0, partial = 0, solid = 0
        for y in 0..<image.height {
            let row = (image.bytes + y * image.stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<image.width {
                switch row[x * 4 + 3] {
                case 0: clear += 1
                case 255: solid += 1
                default: partial += 1
                }
            }
        }
        let total = Double(image.width * image.height)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { (image.bytes + y * image.stride + x * 4 + 3).load(as: UInt8.self) }
        print(String(format: "window %dx%d px in %.0f ms: %.2f%% clear, %.2f%% partial, %.2f%% solid",
                     image.width, image.height, milliseconds(since: clock),
                     100 * Double(clear) / total, 100 * Double(partial) / total, 100 * Double(solid) / total))
        print("corner alpha \(alpha(0, 0)) \(alpha(image.width - 1, 0)) \(alpha(0, image.height - 1)) \(alpha(image.width - 1, image.height - 1)), centre alpha \(alpha(image.width / 2, image.height / 2))")
        _ = out
    }

    private static func editor(to out: URL) async throws {
        let controller = EditorWindowController(image: sampleScreenshot(), fileURL: nil)
        retained.append(controller)
        guard let window = controller.window else { return }
        window.orderBack(nil)
        annotate(controller)
        try await write(window, to: out)
    }

    private static func pin(to out: URL) async throws {
        PinWindowController.pin(sampleScreenshot(size: CGSize(width: 420, height: 260)), at: CGPoint(x: 80, y: 120))
        guard let window = NSApp.windows.first(where: { $0.level == .floating }) else {
            throw CaptureError.failed("the pin window didn't open")
        }
        try await write(window, to: out)
    }

    private static func settings(to out: URL) async throws {
        guard let window = SettingsWindowController.shared.window else { return }
        window.center()
        window.orderBack(nil)
        try await write(window, to: out)
    }

    /// Runs a selection over a synthetic frame: one shot while hovering, one
    /// mid-drag, then checks the region the session reports.
    private static func overlay(to out: URL) async throws {
        let image = sampleScreenshot(size: CGSize(width: 900, height: 560))
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw CaptureError.failed("couldn't allocate a pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<image.height {
            (CVPixelBufferGetBaseAddress(buffer)! + row * stride)
                .copyMemory(from: image.bytes + row * image.stride, byteCount: image.width * 4)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = CGRect(x: visible.minX + 60, y: visible.maxY - 60 - image.size.height,
                                 width: image.size.width, height: image.size.height)
        guard let frame = DisplayFrame(displayID: CGMainDisplayID(), screenFrame: screenFrame, pixelBuffer: buffer) else {
            throw CaptureError.failed("couldn't wrap the pixel buffer")
        }
        var result: SelectionResult?
        let window = WindowCandidate(windowID: 0, frame: screenFrame.insetBy(dx: 48, dy: 40))
        let session = SelectionSession(frames: [frame], mode: .area, candidates: [window], showsLoupe: true) { result = $0 }
        session.isBackgroundDemo = true
        retained.append(session)
        session.begin()
        guard let view = session.views.first, let overlayWindow = view.window else { return }

        // View coordinates are bottom-left based; the sample's headline sits near the top.
        let hover = CGPoint(x: 96, y: 560 - 128)
        view.mouseMoved(with: mouseEvent(.mouseMoved, at: hover, in: view))
        try await write(overlayWindow, to: out.deletingPathExtension().appendingPathExtension("hover.png"))

        let start = CGPoint(x: 70, y: 560 - 90)
        let end = CGPoint(x: 470, y: 560 - 250)
        drag(in: view, from: start, to: end, release: false)
        try await write(overlayWindow, to: out.deletingPathExtension().appendingPathExtension("drag.png"))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, in: view))

        guard case .region(let picked, let rect)? = result else {
            throw CaptureError.failed("the selection didn't report a region")
        }
        print("selected \(rect.x),\(rect.y) \(rect.width)x\(rect.height) px")
        guard rect == PixelRect(x: 140, y: 180, width: 800, height: 320) else {
            throw CaptureError.failed("expected 140,180 800x320")
        }
        try picked.image(cropping: rect)?.pngData().write(to: out)

        // Window mode: hovering inside the candidate should offer its bounds.
        result = nil
        let windowSession = SelectionSession(frames: [frame], mode: .window, candidates: [window], showsLoupe: true) { result = $0 }
        windowSession.isBackgroundDemo = true
        retained.append(windowSession)
        windowSession.begin()
        guard let windowView = windowSession.views.first, let windowOverlay = windowView.window else { return }
        windowView.mouseMoved(with: mouseEvent(.mouseMoved, at: CGPoint(x: 300, y: 300), in: windowView))
        try await write(windowOverlay, to: out.deletingPathExtension().appendingPathExtension("window.png"))
        click(in: windowView, at: CGPoint(x: 300, y: 300))
        guard case .window(_, let windowRect, _)? = result else {
            throw CaptureError.failed("window mode didn't report a window")
        }
        print("window \(windowRect.x),\(windowRect.y) \(windowRect.width)x\(windowRect.height) px")
        guard windowRect == PixelRect(x: 96, y: 80, width: 1608, height: 960) else {
            throw CaptureError.failed("expected 96,80 1608x960")
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// The real thing, briefly: grabs the displays, puts the selection
    /// overlay over them, drags out a region and checks what comes back.
    private static func live(to out: URL) async throws {
        guard ScreenCapturer.hasPermission else { throw CaptureError.permissionDenied }
        var clock = ContinuousClock.now
        var frames = try await ScreenCapturer.shared.captureDisplays()
        print(String(format: "cold capture      %6.1f ms", milliseconds(since: clock)))
        try await Task.sleep(for: .milliseconds(300))

        for _ in 0..<5 {
            clock = ContinuousClock.now
            frames = try await ScreenCapturer.shared.captureDisplays()
            print(String(format: "warm capture      %6.1f ms", milliseconds(since: clock)))
            try await Task.sleep(for: .milliseconds(120))
        }

        // The same sequence a hotkey press runs, timed end to end.
        SelectionSession.prewarm()
        try await Task.sleep(for: .milliseconds(200))
        let mouse = NSEvent.mouseLocation
        let pointerDisplay = NSScreen.screens.first { $0.frame.contains(mouse) }?.displayID
        var candidates: [WindowCandidate] = []
        var result: SelectionResult?
        var session: SelectionSession?
        frames = []
        clock = ContinuousClock.now
        let start = clock
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ScreenCapturer.shared.captureDisplays(startingWith: pointerDisplay, onFrame: { frame in
                frames.append(frame)
                if let session {
                    session.add(frame)
                    print(String(format: "  next display    %6.1f ms", milliseconds(since: start)))
                } else {
                    let captured = milliseconds(since: start)
                    let first = SelectionSession(frames: [frame], mode: .area, candidates: candidates, showsLoupe: true) { result = $0 }
                    session = first
                    first.begin()
                    CATransaction.flush()
                    print(String(format: "hotkey to overlay %6.1f ms (capture %.1f ms, %d windows listed)",
                                 milliseconds(since: start), captured, candidates.count))
                }
            }, completion: { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
            candidates = WindowCandidate.onScreen()
        }
        guard let session else { return }

        for (view, frame) in zip(session.views, frames) {
            guard let window = view.window, window.isVisible, window.frame == frame.screenFrame else {
                session.finish(.cancelled)
                throw CaptureError.failed("overlay for display \(frame.displayID) isn't covering \(frame.screenFrame)")
            }
            print("display \(frame.displayID): \(frame.width)x\(frame.height) px over \(window.frame), level \(window.level.rawValue)")
        }
        try await Task.sleep(for: .milliseconds(200))
        print("overlay is key: \(session.views.contains { $0.window?.isKeyWindow == true })")
        let crosshair = NSCursor.crosshair
        let current = NSCursor.currentSystem
        print("system cursor is the crosshair: \(current?.hotSpot == crosshair.hotSpot && current?.image.size == crosshair.image.size)")

        guard let view = session.views.first, let frame = frames.first else { return }
        guard frame.displayID == pointerDisplay else {
            session.finish(.cancelled)
            throw CaptureError.failed("the pointer's display wasn't captured first")
        }
        let height = view.bounds.height
        drag(in: view, from: CGPoint(x: 200, y: height - 150), to: CGPoint(x: 700, y: height - 450))
        guard case .region(let picked, let rect)? = result else {
            session.finish(.cancelled)
            throw CaptureError.failed("the selection didn't report a region")
        }
        let scale = Int(frame.scale)
        print("selected \(rect.x),\(rect.y) \(rect.width)x\(rect.height) px")
        guard picked === frame, rect == PixelRect(x: 200 * scale, y: 150 * scale, width: 500 * scale, height: 300 * scale) else {
            throw CaptureError.failed("unexpected region")
        }
        guard let image = picked.image(cropping: rect) else { return }
        clock = ContinuousClock.now
        let png = image.pngData(level: 4)
        print(String(format: "crop to PNG       %6.1f ms (%d KB)", milliseconds(since: clock), png.count / 1024))
        try png.write(to: out)
    }

    /// Checks that an editor opened from the background really comes to the
    /// front with keyboard focus, which is what happens after every capture.
    private static func activation() async throws {
        let controller = EditorWindowController.open(sampleScreenshot(), fileURL: nil)
        try await Task.sleep(for: .milliseconds(700))
        let isKey = controller.window?.isKeyWindow ?? false
        print("app active: \(NSApp.isActive), editor key: \(isKey), first responder is canvas: \(controller.window?.firstResponder === controller.canvas)")
        Toast.show("Copied to clipboard")
        try await Task.sleep(for: .milliseconds(500))
        let toastVisible = NSApp.windows.contains { $0.level == .statusBar && $0.isVisible }
        print("toast visible: \(toastVisible)")
        controller.window?.close()
        guard NSApp.isActive, isKey, toastVisible else { throw CaptureError.failed("activation check failed") }
    }

    /// Scrolls a window of our own under a real scrolling capture and checks
    /// the stitched height. Whatever the user's settings say happens to the
    /// result (run with `-saveAfterCapture YES -saveFolder ...` to keep it).
    private static func scroll(to out: URL) async throws {
        guard ScreenCapturer.hasPermission else { throw CaptureError.permissionDenied }
        let viewport = CGSize(width: 420, height: 360)
        let document = TallDocumentView(frame: CGRect(x: 0, y: 0, width: viewport.width, height: 2400))
        let scrollView = NSScrollView(frame: CGRect(origin: .zero, size: viewport))
        scrollView.documentView = document
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: visible.maxX - viewport.width - 80, y: visible.maxY - viewport.height - 80)
        let window = NSPanel(contentRect: CGRect(origin: origin, size: viewport),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = scrollView
        window.orderFrontRegardless()
        retained.append(window)
        document.scroll(.zero)
        try await Task.sleep(for: .milliseconds(400))

        let scale = window.backingScaleFactor
        ScrollCaptureController.shared.start(displayID: window.screen?.displayID ?? CGMainDisplayID(), screenRect: window.frame)
        try await Task.sleep(for: .milliseconds(700))
        // Uneven steps, like a hand on a trackpad.
        var offset: CGFloat = 0
        let steps: [CGFloat] = [18, 40, 73, 25, 110, 64, 150, 91, 33, 127, 58, 140, 80, 96, 45]
        for step in steps {
            offset += step
            document.scroll(CGPoint(x: 0, y: offset))
            try await Task.sleep(for: .milliseconds(160))
        }
        try await Task.sleep(for: .milliseconds(500))
        let folder = Settings.shared.saveFolder
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        ScrollCaptureController.shared.stop(keep: true)
        window.orderOut(nil)

        let expected = Int((viewport.height + offset) * scale)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        guard let name = after.subtracting(before).first,
              let stitched = ImageFile.load(folder.appendingPathComponent(name))
        else { throw CaptureError.failed("no stitched image was saved to \(folder.path)") }
        print("stitched \(stitched.width)x\(stitched.height) px, expected \(Int(viewport.width * scale))x\(expected)")
        try stitched.pngData().write(to: out)
        guard stitched.height == expected else { throw CaptureError.failed("stitched height is off") }
    }

    // MARK: Capture

    /// Photographs one of our own windows, wherever it sits in the window stack.
    private static func write(_ window: NSWindow, to out: URL) async throws {
        window.displayIfNeeded()
        // Give Core Animation a moment to commit and the window server to catch up.
        try await Task.sleep(for: .milliseconds(350))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.failed("the window isn't visible to ScreenCaptureKit")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try PixelImage(cgImage: image, scale: scale).pngData().write(to: out)
        print("wrote \(out.path) (\(image.width)x\(image.height))")
    }
}

/// A long page of numbered rows for the scrolling capture test.
private final class TallDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let rowHeight: CGFloat = 40
        for row in 0..<Int(bounds.height / rowHeight) {
            let rect = CGRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            NSColor(hue: CGFloat(row % 12) / 12, saturation: 0.25, brightness: 1, alpha: 1).setFill()
            rect.insetBy(dx: 12, dy: 5).fill()
            NSAttributedString(string: String(format: "Row %03d of the scrolling capture test", row + 1), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.black,
            ]).draw(at: CGPoint(x: 24, y: rect.minY + 11))
        }
    }
}
