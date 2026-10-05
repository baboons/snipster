import AppKit
import Carbon.HIToolbox

/// A screenshot floating above every other window, for keeping a reference in
/// view. Drag to move, scroll to resize, Esc to dismiss.
@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    private static var pins: [PinWindowController] = []

    private let panel: PinPanel
    private let image: PixelImage

    static func pin(_ image: PixelImage, at origin: CGPoint? = nil) {
        let controller = PinWindowController(image: image, origin: origin)
        pins.append(controller)
        controller.panel.makeKeyAndOrderFront(nil)
    }

    private init(image: PixelImage, origin: CGPoint?) {
        self.image = image
        let mouse = NSEvent.mouseLocation
        let anchor = origin ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Never open larger than most of the screen.
        let fit = min(1, visible.width * 0.8 / image.size.width, visible.height * 0.8 / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        var position = origin ?? NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        position.x = min(max(position.x, visible.minX), visible.maxX - size.width)
        position.y = min(max(position.y, visible.minY), visible.maxY - size.height)

        panel = PinPanel(contentRect: NSRect(origin: position, size: size),
                         styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentAspectRatio = image.size
        panel.minSize = NSSize(width: 60, height: 60 * image.size.height / max(image.size.width, 1))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let view = PinView(image: image)
        view.controller = self
        panel.contentView = view
        panel.initialFirstResponder = view
    }

    func windowWillClose(_ notification: Notification) {
        PinWindowController.pins.removeAll { $0 === self }
    }

    @objc func copyImage(_ sender: Any?) {
        Clipboard.copy(image)
        Toast.show("Copied to clipboard", on: panel.screen)
    }

    @objc func saveImage(_ sender: Any?) {
        do {
            let url = try ImageFile.save(image, in: Settings.shared.saveFolder)
            Toast.show("Saved \(url.lastPathComponent)", on: panel.screen)
        } catch {
            Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", on: panel.screen)
        }
    }

    @objc func editImage(_ sender: Any?) {
        panel.close()
        EditorWindowController.open(image, fileURL: nil)
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        panel.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc func closePin(_ sender: Any?) {
        panel.close()
    }

    /// Grows or shrinks the pin around its centre.
    func resize(by factor: CGFloat) {
        let frame = panel.frame
        let limit = (panel.screen?.visibleFrame.size ?? NSSize(width: 4000, height: 4000))
        var width = frame.width * factor
        width = min(max(width, panel.minSize.width), limit.width, limit.height * image.size.width / image.size.height)
        let height = width * image.size.height / image.size.width
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key) in [
            ("Copy", #selector(copyImage(_:)), "c"), ("Save", #selector(saveImage(_:)), "s"),
            ("Edit…", #selector(editImage(_:)), "e"),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacity.submenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = Int((panel.alphaValue * 100).rounded()) == percent ? .on : .off
            opacity.submenu?.addItem(item)
        }
        menu.addItem(opacity)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close", action: #selector(closePin(_:)), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        return menu
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinView: NSView {
    weak var controller: PinWindowController?

    init(image: PixelImage) {
        super.init(frame: .zero)
        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        self.layer = layer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.editImage(nil)
        } else {
            window?.makeKey()
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        controller?.resize(by: 1 + delta)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.makeMenu()
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: controller?.closePin(nil)
        case kVK_ANSI_W where command: controller?.closePin(nil)
        case kVK_ANSI_C where command: controller?.copyImage(nil)
        case kVK_ANSI_S where command: controller?.saveImage(nil)
        case kVK_ANSI_E where command: controller?.editImage(nil)
        default: super.keyDown(with: event)
        }
    }

    // Without a main menu entry for them, Command shortcuts arrive here first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_S, kVK_ANSI_E:
            keyDown(with: event)
            return true
        default:
            return false
        }
    }
}
