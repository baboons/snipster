import AppKit

/// The popover behind the toolbar's frame button: window frame, backdrop,
/// padding, corner rounding and shadow for the finished screenshot.
final class DecorationPanel: NSViewController, NSTextFieldDelegate {
    /// Called with the new style whenever a control changes it.
    var onChange: ((Decoration) -> Void)?

    /// The style the controls show. Setting it does not call `onChange`.
    var decoration = Decoration() {
        didSet {
            if isViewLoaded, decoration != oldValue { syncControls() }
        }
    }

    private static let solids: [(name: String, hex: UInt32)] = [
        ("White", 0xFFFFFF), ("Light grey", 0xF4F4F5), ("Dark grey", 0x27272A), ("Black", 0x000000),
    ]

    private let windowControl = NSSegmentedControl(labels: ["None", "Light", "Dark"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let titleField = NSTextField()
    private var swatches: [BackdropSwatch] = []
    private let colorWell = NSColorWell(style: .minimal)
    private let paddingSlider = NSSlider()
    private let radiusSlider = NSSlider()
    private let shadowBox = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let newCapturesBox = NSButton(checkboxWithTitle: "Use for new area and window captures", target: nil, action: nil)

    override func loadView() {
        windowControl.target = self
        windowControl.action = #selector(windowChanged)
        windowControl.segmentDistribution = .fillEqually

        titleField.placeholderString = "Window title"
        titleField.delegate = self
        titleField.lineBreakMode = .byTruncatingTail

        var plain: [NSView] = [makeSwatch(.none, toolTip: "Transparent")]
        plain += DecorationPanel.solids.map { makeSwatch(.solid(NSColor(hex: $0.hex)), toolTip: $0.name) }
        colorWell.toolTip = "Any colour"
        colorWell.target = self
        colorWell.action = #selector(customColorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        plain.append(colorWell)
        if Wallpaper.image != nil { plain.append(makeSwatch(.wallpaper, toolTip: "Desktop picture")) }
        let gradients = GradientPreset.all.map { makeSwatch(.gradient($0.id), toolTip: $0.id.capitalized) }
        let backdrops = NSStackView(views: [DecorationPanel.row(plain), DecorationPanel.row(gradients)])
        backdrops.orientation = .vertical
        backdrops.alignment = .leading
        backdrops.spacing = 6

        configure(paddingSlider, range: Decoration.paddingRange)
        configure(radiusSlider, range: Decoration.cornerRadiusRange)
        shadowBox.target = self
        shadowBox.action = #selector(shadowChanged)
        newCapturesBox.target = self
        newCapturesBox.action = #selector(newCapturesChanged)
        newCapturesBox.state = Settings.shared.decorateNewCaptures ? .on : .off

        let grid = NSGridView(views: [
            [DecorationPanel.label("Window"), windowControl],
            [DecorationPanel.label("Title"), titleField],
            [DecorationPanel.label("Background"), backdrops],
            [DecorationPanel.label("Padding"), paddingSlider],
            [DecorationPanel.label("Corners"), radiusSlider],
            [NSGridCell.emptyContentView, shadowBox],
            [NSGridCell.emptyContentView, newCapturesBox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 2).rowAlignment = .none
        grid.row(at: 2).yPlacement = .top
        grid.row(at: 6).topPadding = 4
        for control in [windowControl, titleField, paddingSlider, radiusSlider] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        view = container
        syncControls()
    }

    private func makeSwatch(_ backdrop: Decoration.Backdrop, toolTip: String) -> BackdropSwatch {
        let swatch = BackdropSwatch(backdrop: backdrop)
        swatch.toolTip = toolTip
        swatch.onClick = { [weak self] in self?.change { $0.backdrop = backdrop } }
        swatches.append(swatch)
        return swatch
    }

    private func configure(_ slider: NSSlider, range: ClosedRange<CGFloat>) {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 4
        return stack
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: State

    private func change(_ edit: (inout Decoration) -> Void) {
        var next = decoration
        edit(&next)
        guard next != decoration else { return }
        decoration = next
        onChange?(next)
    }

    private func syncControls() {
        windowControl.selectedSegment = Decoration.WindowStyle.allCases.firstIndex(of: decoration.window) ?? 0
        if titleField.stringValue != decoration.title { titleField.stringValue = decoration.title }
        titleField.isEnabled = decoration.window != .none
        for swatch in swatches { swatch.isOn = swatch.backdrop.matches(decoration.backdrop) }
        if case .solid(let color) = decoration.backdrop { colorWell.color = color }
        paddingSlider.doubleValue = Double(decoration.padding)
        radiusSlider.doubleValue = Double(decoration.cornerRadius)
        shadowBox.state = decoration.hasShadow ? .on : .off
        // Padding, corners and shadow only mean something around a frame or backdrop.
        for control in [paddingSlider, radiusSlider, shadowBox] as [NSControl] { control.isEnabled = !decoration.isEmpty }
    }

    @objc private func windowChanged() {
        let styles = Decoration.WindowStyle.allCases
        let index = windowControl.selectedSegment
        guard styles.indices.contains(index) else { return }
        change { $0.window = styles[index] }
    }

    @objc private func customColorChanged() {
        let color = colorWell.color
        change { $0.backdrop = .solid(color) }
    }

    @objc private func sliderChanged() {
        change {
            $0.padding = CGFloat(paddingSlider.doubleValue).rounded()
            $0.cornerRadius = CGFloat(radiusSlider.doubleValue).rounded()
        }
    }

    @objc private func shadowChanged() {
        change { $0.hasShadow = shadowBox.state == .on }
    }

    @objc private func newCapturesChanged() {
        Settings.shared.decorateNewCaptures = newCapturesBox.state == .on
    }

    func controlTextDidChange(_ notification: Notification) {
        change { $0.title = titleField.stringValue }
    }
}

extension Decoration.Backdrop {
    /// Equality that survives a colour's trip through the colour picker or
    /// the saved settings (same shade, different colour space or precision).
    func matches(_ other: Decoration.Backdrop) -> Bool {
        if case .solid(let a) = self, case .solid(let b) = other { return a.hexString == b.hexString }
        return self == other
    }
}

/// A small preview of one backdrop choice.
final class BackdropSwatch: NSButton {
    let backdrop: Decoration.Backdrop
    var onClick: (() -> Void)?
    var isOn = false {
        didSet { needsDisplay = true }
    }

    init(backdrop: Decoration.Backdrop) {
        self.backdrop = backdrop
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clicked() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let chip = bounds.insetBy(dx: 3, dy: 3)
        let outline = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        switch backdrop {
        case .none:
            // Transparent: the checkerboard everyone knows.
            NSColor.white.setFill()
            chip.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            let square: CGFloat = 4.5
            for row in 0..<Int(chip.height / square) + 1 {
                for column in 0..<Int(chip.width / square) + 1 where (row + column) % 2 == 0 {
                    NSRect(x: chip.minX + CGFloat(column) * square, y: chip.minY + CGFloat(row) * square,
                           width: square, height: square).fill()
                }
            }
        case .solid(let color):
            color.setFill()
            chip.fill()
        case .gradient(let id):
            if let preset = GradientPreset.named(id) { DecorationRenderer.fill(chip, with: preset, context: context) }
        case .wallpaper:
            if let wallpaper = Wallpaper.image {
                let scale = max(chip.width / CGFloat(wallpaper.width), chip.height / CGFloat(wallpaper.height))
                let size = CGSize(width: CGFloat(wallpaper.width) * scale, height: CGFloat(wallpaper.height) * scale)
                context.interpolationQuality = .high
                context.draw(wallpaper, in: CGRect(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2,
                                                   width: size.width, height: size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if isOn {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
