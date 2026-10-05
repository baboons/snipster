import AppKit

/// Runs a capture from hotkey to finished image: grab every display, let the
/// user pick a region on the frozen frames if the action needs one, then hand
/// the result to wherever it belongs.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var session: SelectionSession?
    private var isCapturing = false

    private init() {}

    var isBusy: Bool { session != nil || isCapturing || ScrollCaptureController.shared.isActive }

    func perform(_ action: CaptureAction) {
        guard !isBusy else { return }
        guard ScreenCapturer.hasPermission else {
            Permissions.explainScreenRecording()
            return
        }
        isCapturing = true
        let mouse = NSEvent.mouseLocation
        let pointerDisplay = NSScreen.screens.first { $0.frame.contains(mouse) }?.displayID
        var candidates: [WindowCandidate] = []
        // The selection this capture started. Frames for the other displays
        // join it as they arrive, unless the user has already finished.
        weak var started: SelectionSession?
        var hasStarted = false

        ScreenCapturer.shared.captureDisplays(
            startingWith: pointerDisplay, onlyFirst: action == .fullscreen,
            onFrame: { [weak self] frame in
                guard let self else { return }
                if action == .fullscreen {
                    if let image = frame.image(cropping: frame.pixelBounds) { CaptureOutput.deliver(image) }
                } else if !hasStarted {
                    hasStarted = true
                    started = self.select(for: action, firstFrame: frame, candidates: candidates)
                } else {
                    started?.add(frame)
                }
            },
            completion: { [weak self] error in
                self?.isCapturing = false
                if let error { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill") }
            })
        // The capture is already in flight; use the wait to read the window
        // list, which also has to happen before any of our own windows exist.
        if action != .fullscreen { candidates = WindowCandidate.onScreen() }
        if action == .window { ScreenCapturer.shared.prepareWindowCapture() }
    }

    private func select(for action: CaptureAction, firstFrame: DisplayFrame, candidates: [WindowCandidate]) -> SelectionSession {
        let session = SelectionSession(
            frames: [firstFrame], mode: action == .window ? .window : .area, candidates: candidates,
            showsLoupe: Settings.shared.showLoupe
        ) { [weak self] result in
            self?.session = nil
            self?.finish(action, with: result)
        }
        self.session = session
        session.begin()
        return session
    }

    private func finish(_ action: CaptureAction, with result: SelectionResult) {
        switch result {
        case .cancelled:
            break
        case .color(let color):
            Clipboard.copy(color.hex)
            Toast.show("Copied \(color.hex)", symbol: "eyedropper.halffull")
        case .window(let frame, let rect, let windowID) where action == .area || action == .window:
            Task {
                // Prefer the window on its own, with its true outline; fall
                // back to its rectangle of the frozen screen.
                guard let image = await ScreenCapturer.shared.captureWindow(windowID) ?? frame.image(cropping: rect) else { return }
                CaptureOutput.deliver(image, decorating: true)
            }
        case .region(let frame, let rect), .window(let frame, let rect, _):
            switch action {
            case .scrolling:
                let scale = frame.scale
                let screenRect = CGRect(
                    x: frame.screenFrame.minX + CGFloat(rect.x) / scale,
                    y: frame.screenFrame.maxY - CGFloat(rect.y + rect.height) / scale,
                    width: CGFloat(rect.width) / scale, height: CGFloat(rect.height) / scale)
                ScrollCaptureController.shared.start(displayID: frame.displayID, screenRect: screenRect)
            case .recognizeText:
                guard let image = frame.image(cropping: rect) else { return }
                Task {
                    let text = await TextRecognizer.recognize(image)
                    if text.isEmpty {
                        Toast.show("No text found", symbol: "text.viewfinder")
                    } else {
                        Clipboard.copy(text)
                        Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
                    }
                }
            case .area, .window, .fullscreen:
                guard let image = frame.image(cropping: rect) else { return }
                CaptureOutput.deliver(image, decorating: true)
            }
        }
    }
}

@MainActor
enum Permissions {
    private static var hasPrompted = false

    /// Asks for Screen Recording. macOS shows its own prompt the first time;
    /// after that only System Settings can change the answer, so point there.
    static func explainScreenRecording() {
        if !hasPrompted {
            hasPrompted = true
            if ScreenCapturer.requestPermission() { return }
        }
        let alert = NSAlert()
        alert.messageText = "Snipster needs Screen Recording access"
        alert.informativeText = "Allow Snipster under Privacy & Security › Screen & System Audio Recording, then quit and reopen it. Screenshots never leave your Mac."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        Activation.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
