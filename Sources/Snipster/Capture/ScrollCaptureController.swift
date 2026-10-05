import AppKit
import Carbon.HIToolbox
import CSnipsterCore

/// Scrolling capture: keeps grabbing one screen region while the user scrolls
/// the content under it, and feeds the frames to the Rust stitcher.
@MainActor
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private(set) var isActive = false
    private var outline: NSPanel?
    private var controls: NSPanel?
    private var statusLabel: NSTextField?
    private var loop: Task<Void, Never>?
    private var hotKeys: [UInt32] = []
    private var stitcher: OpaquePointer?
    private var frameSize: (width: Int, height: Int) = (0, 0)
    private var scale: CGFloat = 1

    private init() {}

    func start(displayID: CGDirectDisplayID, screenRect: CGRect) {
        guard !isActive, screenRect.width >= 40, screenRect.height >= 60 else {
            Toast.show("Select a taller area to scroll", symbol: "exclamationmark.triangle.fill")
            return
        }
        isActive = true
        showOutline(around: screenRect)
        showControls(for: screenRect)
        // Return and Escape as temporary global shortcuts: the app being
        // scrolled keeps keyboard focus, so ordinary key events never reach us.
        if let id = HotKeyCenter.shared.register(KeyCombo(keyCode: UInt32(kVK_Return), modifiers: []), handler: { [weak self] in self?.stop(keep: true) }) {
            hotKeys.append(id)
        }
        if let id = HotKeyCenter.shared.register(KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: []), handler: { [weak self] in self?.stop(keep: false) }) {
            hotKeys.append(id)
        }

        let ownWindows = [outline, controls].compactMap { $0.map { CGWindowID($0.windowNumber) } }
        loop = Task { [weak self] in
            await ScreenCapturer.shared.prepareRegionCapture(displayID: displayID, hiding: ownWindows)
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                do {
                    let image = try await ScreenCapturer.shared.captureRegion(screenRect, displayID: displayID)
                    guard !Task.isCancelled, self.isActive else { return }
                    failures = 0
                    self.push(image)
                } catch {
                    failures += 1
                    if failures >= 5 {
                        self.stop(keep: true)
                        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func push(_ image: PixelImage) {
        if stitcher == nil {
            frameSize = (image.width, image.height)
            scale = image.scale
            // Leave overlay scrollbars out of the matching: their thumb moves
            // at a different rate than the content.
            let ignored = image.width >= 400 ? Int(18 * image.scale) : 0
            stitcher = snip_stitcher_new(image.width, image.height, ignored)
        }
        guard let stitcher, image.width == frameSize.width, image.height == frameSize.height else { return }
        let appended = snip_stitcher_push(stitcher, image.bytes.assumingMemoryBound(to: UInt8.self), image.stride)
        let height = snip_stitcher_height(stitcher)
        switch appended {
        case Int64(SNIP_STITCH_NO_MATCH):
            setStatus("Lost track: scroll back up a little", warning: true)
        case Int64(SNIP_STITCH_FULL):
            stop(keep: true)
            Toast.show("Reached the maximum scrolling capture size", symbol: "exclamationmark.triangle.fill")
        default:
            setStatus(height > frameSize.height ? "Capturing… \(height) px tall" : "Scroll down slowly", warning: false)
        }
    }

    private func setStatus(_ text: String, warning: Bool) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = warning ? .systemYellow : .white
    }

    /// Ends the session; `keep` decides whether the stitched image is delivered.
    func stop(keep: Bool) {
        guard isActive else { return }
        isActive = false
        loop?.cancel()
        loop = nil
        for id in hotKeys { HotKeyCenter.shared.unregister(id) }
        hotKeys = []
        outline?.orderOut(nil)
        outline = nil
        controls?.orderOut(nil)
        controls = nil
        statusLabel = nil
        ScreenCapturer.shared.endRegionCapture()

        guard let stitcher else { return }
        self.stitcher = nil
        guard keep else {
            snip_stitcher_free(stitcher)
            return
        }
        var rows = 0
        let buffer = snip_stitcher_finish(stitcher, &rows)
        defer { snip_buffer_free(buffer) }
        guard let pixels = buffer.ptr, rows > 0 else { return }
        let image = PixelImage(
            copying: pixels, stride: frameSize.width * 4,
            rect: PixelRect(x: 0, y: 0, width: frameSize.width, height: rows), scale: scale, opaque: true)
        CaptureOutput.deliver(image)
    }

    // MARK: Windows

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func showOutline(around rect: CGRect) {
        let inset: CGFloat = 4
        let panel = makePanel(frame: rect.insetBy(dx: -inset, dy: -inset))
        panel.ignoresMouseEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        // Drawn entirely outside the captured rectangle.
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = inset - 1
        view.layer?.cornerRadius = inset
        panel.contentView = view
        panel.orderFrontRegardless()
        outline = panel
    }

    private func showControls(for rect: CGRect) {
        let label = NSTextField(labelWithString: "Scroll down slowly")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel = label

        let done = NSButton(title: "Done ↩", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel ⎋", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [label, cancel, done])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 10)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        let size = NSSize(width: max(stack.fittingSize.width + 110, 380), height: stack.fittingSize.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }?.frame ?? rect
        // Prefer below the region, then above it; inside only as a last resort
        // (these windows are filtered out of the capture either way).
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 14)
        if origin.y < screen.minY + 8 { origin.y = rect.maxY + 14 }
        if origin.y + size.height > screen.maxY - 8 { origin.y = rect.minY + 14 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)

        let panel = makePanel(frame: CGRect(origin: origin, size: size))
        panel.hasShadow = true
        panel.contentView = background
        panel.orderFrontRegardless()
        controls = panel
    }

    @objc private func doneClicked() { stop(keep: true) }
    @objc private func cancelClicked() { stop(keep: false) }
}
