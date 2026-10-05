import AppKit

/// The annotation window for one screenshot.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate, CanvasViewDelegate {
    private static var controllers: [EditorWindowController] = []
    private static let toolbarHeight: CGFloat = 44
    private static let minimumContentSize = NSSize(width: 930, height: 420)
    /// Breathing room around the image inside the scroll view.
    private static let canvasMargin: CGFloat = 28

    let canvas: CanvasView
    private let scrollView = ZoomScrollView()
    private let toolbar = EditorToolbar()
    private var fileURL: URL?
    private var strokeColor = Palette.colors[0]
    private var highlightColor = Palette.highlight
    private let decorationPanel = DecorationPanel()
    private lazy var decorationPopover: NSPopover = {
        let popover = NSPopover()
        popover.contentViewController = decorationPanel
        // Stays up while the colour picker is in use, goes away on a click in the editor.
        popover.behavior = .semitransient
        popover.delegate = self
        return popover
    }()

    /// Opens an editor. With `decorated`, the screenshot starts out in the
    /// frame and backdrop last used; otherwise it starts bare, and only the
    /// padding, rounding and shadow preferences carry over for when one is added.
    @discardableResult
    static func open(_ image: PixelImage, fileURL: URL?, decorated: Bool = false) -> EditorWindowController {
        var decoration = Settings.shared.decoration
        if !decorated {
            decoration.window = .none
            decoration.backdrop = .none
        }
        let controller = EditorWindowController(image: image, fileURL: fileURL, decoration: decoration)
        controllers.append(controller)
        Activation.bringToFront()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        return controller
    }

    init(image: PixelImage, fileURL: URL?, decoration: Decoration = Decoration()) {
        canvas = CanvasView(image: image, decoration: decoration)
        self.fileURL = fileURL
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: EditorWindowController.minimumContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = EditorWindowController.minimumContentSize
        super.init(window: window)
        window.delegate = self
        canvas.delegate = self

        buildContent(in: window)
        toolbar.select(tool: canvas.tool)
        toolbar.select(color: strokeColor)
        toolbar.select(lineWidth: canvas.lineWidth)
        toolbar.showDecorated(!decoration.isEmpty)
        canvas.color = strokeColor

        sizeWindowToImage(positioning: true)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        }
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 32
        scrollView.onMagnify = { [weak self] in self?.canvas.needsDisplay = true }

        toolbar.onTool = { [weak self] tool in self?.select(tool) }
        toolbar.onColor = { [weak self] color in self?.pick(color) }
        toolbar.onLineWidth = { [weak self] width in
            guard let self else { return }
            self.canvas.lineWidth = width
            self.canvas.restyleSelection(lineWidth: width)
        }
        toolbar.onAction = { [weak self] action in self?.perform(action) }
        toolbar.onDecoration = { [weak self] button in self?.toggleDecorationPopover(from: button) }
        decorationPanel.onChange = { [weak self] decoration in
            self?.canvas.setDecoration(decoration)
            Settings.shared.decoration = decoration
        }
        toolbar.dragImageProvider = { [weak self] in self?.canvas.renderedImage() }

        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for view in [toolbar, separator, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: EditorWindowController.toolbarHeight),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    // MARK: Layout and zoom

    /// The window frame size that shows the whole picture at 100%, capped to
    /// what the screen has room for, and that room itself.
    private func idealWindowSize() -> (size: NSSize, available: NSRect)? {
        guard let window else { return nil }
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 40, dy: 40)
        let chrome = window.frame.height - window.contentLayoutRect.height + EditorWindowController.toolbarHeight + 1
        let margin = EditorWindowController.canvasMargin * 2
        let picture = canvas.documentSize
        let minimum = EditorWindowController.minimumContentSize
        let width = min(max(picture.width + margin, minimum.width), available.width)
        let height = min(max(picture.height + margin + chrome, minimum.height + chrome), available.height)
        return (NSSize(width: width, height: height), available)
    }

    /// Sizes the window to show the picture at 100% when it fits on screen and
    /// scaled down to fit when it doesn't. With `positioning` the window is
    /// placed afresh; otherwise it only ever grows, around where it already is.
    private func sizeWindowToImage(positioning: Bool) {
        guard let window, let (ideal, available) = idealWindowSize() else { return }
        if positioning {
            let offset = CGFloat((EditorWindowController.controllers.count % 6) * 22)
            let origin = NSPoint(x: available.midX - ideal.width / 2 + offset, y: available.midY - ideal.height / 2 - offset)
            window.setFrame(NSRect(origin: origin, size: ideal), display: false)
        } else if ideal.width > window.frame.width || ideal.height > window.frame.height {
            var frame = window.frame
            let size = NSSize(width: max(frame.width, ideal.width), height: max(frame.height, ideal.height))
            // Keep the title bar where it is and grow evenly sideways and downwards.
            frame.origin.x -= (size.width - frame.width) / 2
            frame.origin.y -= size.height - frame.height
            frame.size = size
            frame.origin.x = min(max(frame.origin.x, available.minX), available.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, available.minY), available.maxY - size.height)
            window.setFrame(frame, display: true)
        }
        window.layoutIfNeeded()
        zoomToFit(allowEnlarging: false)
    }

    private func zoomToFit(allowEnlarging: Bool) {
        let image = canvas.documentSize
        let margin = EditorWindowController.canvasMargin * 2
        let area = scrollView.frame.size
        guard image.width > 0, image.height > 0, area.width > margin, area.height > margin else { return }
        let fit = min((area.width - margin) / image.width, (area.height - margin) / image.height)
        setMagnification(allowEnlarging ? fit : min(fit, 1))
    }

    private func setMagnification(_ value: CGFloat) {
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        canvas.needsDisplay = true
    }

    @objc func zoomIn(_ sender: Any?) { setMagnification(scrollView.magnification * 1.25) }
    @objc func zoomOut(_ sender: Any?) { setMagnification(scrollView.magnification / 1.25) }
    @objc func zoomImageToActualSize(_ sender: Any?) { setMagnification(1) }
    @objc func zoomImageToFit(_ sender: Any?) { zoomToFit(allowEnlarging: true) }

    private func updateTitle() {
        // The size of what will be copied or saved, decoration included.
        let size = canvas.documentSize
        let scale = canvas.state.image.scale
        let name = fileURL?.lastPathComponent ?? "Snipster"
        window?.title = "\(name) — \(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded()))"
    }

    // MARK: Frame and backdrop

    private func toggleDecorationPopover(from button: NSView) {
        if decorationPopover.isShown {
            decorationPopover.performClose(nil)
        } else {
            decorationPanel.decoration = canvas.state.decoration
            decorationPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // The next visit to the popover is a new undo step.
        canvas.endDecorationAdjustment()
        window?.makeFirstResponder(canvas)
    }

    /// Sets the decoration as the popover would. Used by the snapshot harness.
    func decorate(_ decoration: Decoration) {
        canvas.setDecoration(decoration)
    }

    // MARK: Toolbar

    func select(_ tool: Tool) {
        canvas.tool = tool
        toolbar.select(tool: tool)
        // The highlighter keeps its own colour so picking it doesn't turn
        // everything else yellow, and vice versa.
        let color = tool == .highlighter ? highlightColor : strokeColor
        canvas.color = color
        toolbar.select(color: color)
        window?.makeFirstResponder(canvas)
    }

    func pick(_ color: NSColor) {
        if canvas.tool == .highlighter { highlightColor = color } else { strokeColor = color }
        canvas.color = color
        canvas.restyleSelection(color: color)
        toolbar.select(color: color)
    }

    private func perform(_ action: EditorToolbar.Action) {
        switch action {
        case .copy: copy(nil)
        case .save: saveDocument(nil)
        case .pin: pinImage(nil)
        case .recognizeText: recognizeText(nil)
        }
    }

    // MARK: Actions

    @objc func copy(_ sender: Any?) {
        Clipboard.copy(canvas.renderedImage())
        Toast.show("Copied to clipboard", on: window?.screen)
    }

    @objc func saveDocument(_ sender: Any?) {
        let image = canvas.renderedImage()
        do {
            if let fileURL {
                try image.pngData(level: 6).write(to: fileURL, options: .atomic)
            } else {
                fileURL = try ImageFile.save(image, in: Settings.shared.saveFolder)
                updateTitle()
            }
            if let fileURL { Toast.show("Saved \(fileURL.lastPathComponent)", on: window?.screen) }
        } catch {
            presentSaveError(error)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? ImageFile.defaultName()
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? Settings.shared.saveFolder
        let image = canvas.renderedImage()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try image.pngData(level: 6).write(to: url, options: .atomic)
                    self.fileURL = url
                    self.updateTitle()
                } catch {
                    self.presentSaveError(error)
                }
            }
        }
    }

    private func presentSaveError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "The screenshot couldn't be saved"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    @objc func pinImage(_ sender: Any?) {
        guard let window else { return }
        let image = canvas.renderedImage()
        // Put the pin where the picture already is, so it looks like the
        // window chrome simply fell away.
        let onScreen = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
        let visible = onScreen.intersection(window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil)))
        PinWindowController.pin(image, at: visible.isEmpty ? nil : visible.origin)
        window.close()
    }

    @objc func recognizeText(_ sender: Any?) {
        let image = canvas.state.image
        let screen = window?.screen
        Task {
            let text = await TextRecognizer.recognize(image)
            if text.isEmpty {
                Toast.show("No text found", symbol: "text.viewfinder", on: screen)
            } else {
                Clipboard.copy(text)
                Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder", on: screen)
            }
        }
    }

    // MARK: CanvasViewDelegate

    func canvasDidChange(_ canvas: CanvasView) {
        // Undo can change the decoration behind the popover's back.
        decorationPanel.decoration = canvas.state.decoration
        toolbar.showDecorated(!canvas.state.decoration.isEmpty)
        if let selected = canvas.selectedAnnotation {
            toolbar.select(color: selected.color)
            toolbar.select(lineWidth: selected.lineWidth)
        } else {
            toolbar.select(color: canvas.color)
            toolbar.select(lineWidth: canvas.lineWidth)
        }
    }

    func canvasDidResize(_ canvas: CanvasView) {
        updateTitle()
        // Padding and a frame make the picture bigger; give it the room if there is any.
        sizeWindowToImage(positioning: false)
    }

    func canvas(_ canvas: CanvasView, didRequest tool: Tool) {
        select(tool)
    }

    func canvasDidRequestClose(_ canvas: CanvasView) {
        window?.performClose(nil)
    }

    func canvasDidRequestCopyAndClose(_ canvas: CanvasView) {
        copy(nil)
        window?.close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.controllers.removeAll { $0 === self }
    }
}

enum Palette {
    static let colors: [NSColor] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x0A84FF, 0xAF52DE, 0x1C1C1E, 0xFFFFFF]
        .map(NSColor.init(hex:))
    static var highlight: NSColor { colors[2] }
    static let lineWidths: [CGFloat] = [2, 4, 7]
}

/// Keeps the image centred when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A scroll view that zooms around the pointer on Command-scroll, on top of
/// the built-in pinch to zoom.
final class ZoomScrollView: NSScrollView {
    var onMagnify: (() -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMagnify?() }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
        let target = min(max(magnification * (1 + delta), minMagnification), maxMagnification)
        setMagnification(target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        onMagnify?()
    }
}
