import AppKit

/// The strip above the canvas: tools, colours, stroke size and output actions.
final class EditorToolbar: NSView {
    enum Action {
        case copy, save, pin, recognizeText
    }

    var onTool: ((Tool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onLineWidth: ((CGFloat) -> Void)?
    var onAction: ((Action) -> Void)?
    /// The frame and backdrop button was clicked; the popover hangs off it.
    var onDecoration: ((NSView) -> Void)?
    /// Supplies the image to drag out of the window.
    var dragImageProvider: (() -> PixelImage?)? {
        didSet { dragHandle.imageProvider = dragImageProvider }
    }

    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var swatches: [SwatchButton] = []
    private let sizeControl = NSSegmentedControl()
    private let decorationButton = ToolbarButton(symbol: "macwindow.on.rectangle", fallback: "Frame",
                                                 toolTip: "Window frame and background")
    private let dragHandle = DragHandle()

    init() {
        super.init(frame: .zero)

        let tools = NSStackView(views: Tool.allCases.map { tool in
            let button = ToolbarButton(symbol: tool.symbolName, fallback: tool.title,
                                       toolTip: "\(tool.title) (\(tool.shortcut.uppercased()))")
            button.onClick = { [weak self] in self?.onTool?(tool) }
            toolButtons[tool] = button
            return button
        })
        tools.spacing = 1

        swatches = Palette.colors.map { color in
            let swatch = SwatchButton(color: color)
            swatch.onClick = { [weak self] in self?.onColor?(color) }
            return swatch
        }
        let colors = NSStackView(views: swatches)
        colors.spacing = 2

        sizeControl.segmentCount = Palette.lineWidths.count
        sizeControl.trackingMode = .selectOne
        sizeControl.segmentStyle = .rounded
        sizeControl.controlSize = .regular
        for (index, width) in Palette.lineWidths.enumerated() {
            sizeControl.setImage(EditorToolbar.dot(diameter: 3 + width), forSegment: index)
            sizeControl.setWidth(30, forSegment: index)
            sizeControl.setToolTip("Stroke size \(Int(width))", forSegment: index)
        }
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged)

        decorationButton.onClick = { [weak self] in
            guard let self else { return }
            self.onDecoration?(self.decorationButton)
        }

        let actions: [(Action, String, String, String)] = [
            (.recognizeText, "text.viewfinder", "Text", "Copy the text in this screenshot"),
            (.pin, "pin", "Pin", "Pin on top of other windows (⌘P)"),
            (.save, "square.and.arrow.down", "Save", "Save (⌘S)"),
        ]
        let actionButtons: [NSView] = actions.map { action, symbol, fallback, tip in
            let button = ToolbarButton(symbol: symbol, fallback: fallback, toolTip: tip)
            button.onClick = { [weak self] in self?.onAction?(action) }
            return button
        }
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copy.bezelStyle = .rounded
        copy.bezelColor = .controlAccentColor
        copy.toolTip = "Copy (⌘C). Return copies and closes."

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [tools, EditorToolbar.divider(), colors, EditorToolbar.divider(), sizeControl,
                                      EditorToolbar.divider(), decorationButton, spacer, dragHandle]
                              + actionButtons + [copy])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func select(tool: Tool) {
        for (candidate, button) in toolButtons { button.isOn = candidate == tool }
    }

    func select(color: NSColor) {
        for swatch in swatches { swatch.isOn = swatch.color == color }
    }

    /// Lights the frame button up while the screenshot is decorated.
    func showDecorated(_ decorated: Bool) {
        decorationButton.isOn = decorated
    }

    func select(lineWidth: CGFloat) {
        // Snap to the nearest preset so a restyled selection still shows one.
        let nearest = Palette.lineWidths.enumerated().min { abs($0.element - lineWidth) < abs($1.element - lineWidth) }
        sizeControl.selectedSegment = nearest?.offset ?? 1
    }

    @objc private func sizeChanged() {
        let index = sizeControl.selectedSegment
        guard Palette.lineWidths.indices.contains(index) else { return }
        onLineWidth?(Palette.lineWidths[index])
    }

    @objc private func copyClicked() {
        onAction?(.copy)
    }

    private static func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .separatorColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private static func dot(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// An icon button that shows a filled accent background while selected.
final class ToolbarButton: NSButton {
    var onClick: (() -> Void)?
    var isOn = false {
        didSet {
            contentTintColor = isOn ? .white : .labelColor
            needsDisplay = true
        }
    }

    init(symbol: String, fallback: String, toolTip: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            self.image = image.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            imagePosition = .imageOnly
            title = ""
        } else {
            title = fallback
            font = .systemFont(ofSize: 11, weight: .medium)
        }
        contentTintColor = .labelColor
        self.toolTip = toolTip
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A round colour chip; the selected one gets a ring.
final class SwatchButton: NSButton {
    let color: NSColor
    var onClick: (() -> Void)?
    var isOn = false {
        didSet { needsDisplay = true }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let chip = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: chip).fill()
        // A hairline keeps white and black chips visible in either appearance.
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let edge = NSBezierPath(ovalIn: chip.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
        if isOn {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.25, dy: 1.25))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

/// Drag from here to drop the finished screenshot into another app as a file.
final class DragHandle: NSView, NSDraggingSource {
    var imageProvider: (() -> PixelImage?)?
    private let icon = NSImageView()
    private var mouseDownEvent: NSEvent?

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: "Drag out")
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.unregisterDraggedTypes()
        addSubview(icon)
        toolTip = "Drag into another app to drop the screenshot there"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // The image view would otherwise swallow the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let image = imageProvider?() else { return }
        mouseDownEvent = nil
        // Other apps want a file, so write one into a scratch folder first.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Snipster", isDirectory: true)
        guard let url = try? ImageFile.save(image, in: folder) else { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let longest = max(image.size.width, image.size.height)
        let ratio = min(1, 160 / max(longest, 1))
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let origin = convert(start.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                                     width: size.width, height: size.height), contents: image.nsImage)
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
