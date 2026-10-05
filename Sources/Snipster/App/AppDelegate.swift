import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyTokens: [UInt32] = []
    /// Actions whose shortcut the system refused, shown in the menu.
    private var unavailableShortcuts: Set<CaptureAction> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            // A second copy would fight the first over the global shortcuts.
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = makeMainMenu()
        updateStatusItem()
        // The settings window writes straight to UserDefaults; follow along.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        registerHotKeys()
        NotificationCenter.default.addObserver(
            forName: Settings.hotKeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SelectionSession.prewarm() }
        }

        // Do everything slow now, so a hotkey press only has to take the picture.
        SelectionSession.prewarm()
        if ScreenCapturer.hasPermission {
            ScreenCapturer.shared.warmUp()
        } else {
            ScreenCapturer.requestPermission()
        }

        // `Snipster --capture area` starts a capture right after launch.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--capture"), index + 1 < arguments.count,
           let action = CaptureAction(rawValue: arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                CaptureController.shared.perform(action)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Launching Snipster again while it is running opens its settings. With
    /// the menu bar icon hidden, that is the only way back to them.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows || !Settings.shared.showMenuBarIcon { SettingsWindowController.shared.show() }
        return true
    }

    /// Image files open in the editor; `snipster://capture/<action>` URLs
    /// start a capture, so other tools can script Snipster.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "snipster" {
                handleCommand(url)
            } else {
                openImage(at: url)
            }
        }
    }

    private func handleCommand(_ url: URL) {
        guard url.host == "capture", let action = CaptureAction(rawValue: url.lastPathComponent) else { return }
        CaptureController.shared.perform(action)
    }

    // MARK: Shortcuts

    private func registerHotKeys() {
        for token in hotKeyTokens { HotKeyCenter.shared.unregister(token) }
        hotKeyTokens = []
        unavailableShortcuts = []
        for action in CaptureAction.allCases {
            guard let combo = Settings.shared.combo(for: action) else { continue }
            if let token = HotKeyCenter.shared.register(combo, handler: { CaptureController.shared.perform(action) }) {
                hotKeyTokens.append(token)
            } else {
                unavailableShortcuts.insert(action)
            }
        }
    }

    // MARK: Menu bar

    /// Adds or removes the menu bar item to match the setting.
    private func updateStatusItem() {
        if Settings.shared.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // Remembers where the user dragged it, also across hiding and showing.
            item.autosaveName = "Snipster"
            item.button?.image = StatusIcon.image
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !ScreenCapturer.hasPermission {
            let item = NSMenuItem(title: "Grant Screen Recording Access…", action: #selector(grantAccess), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for action in CaptureAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(capture(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            item.target = self
            if let combo = Settings.shared.combo(for: action), !unavailableShortcuts.contains(action) {
                item.keyEquivalent = combo.menuKeyEquivalent
                item.keyEquivalentModifierMask = combo.modifiers
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clipboard = NSMenuItem(title: "Edit Image from Clipboard", action: #selector(openClipboard), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)
        let open = NSMenuItem(title: "Open Image…", action: #selector(openDocument(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Snipster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CaptureAction(rawValue: raw) else { return }
        // Let the menu finish closing so it isn't part of the picture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            CaptureController.shared.perform(action)
        }
    }

    @objc private func grantAccess() {
        Permissions.explainScreenRecording()
    }

    @objc private func openClipboard() {
        if let image = Clipboard.image() {
            EditorWindowController.open(image, fileURL: nil)
        } else {
            Toast.show("No image on the clipboard", symbol: "clipboard")
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        Activation.bringToFront()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openImage(at: url) }
    }

    private func openImage(at url: URL) {
        guard let image = ImageFile.load(url) else {
            Toast.show("Couldn't open \(url.lastPathComponent)", symbol: "exclamationmark.triangle.fill")
            return
        }
        // Only PNGs are edited in place; anything else is saved as a new file.
        EditorWindowController.open(image, fileURL: url.pathExtension.lowercased() == "png" ? url : nil)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    // MARK: Main menu

    /// Snipster has no menu bar of its own (it is an accessory app), but the
    /// main menu is still what routes Command shortcuts to the key window.
    private func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        let main = NSMenu()
        main.addItem(submenu("Snipster", [
            item("About Snipster", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            .separator(),
            item("Quit Snipster", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(EditorWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Pin on Top", #selector(EditorWindowController.pinImage(_:)), "p"),
            item("Copy Text in Image", #selector(EditorWindowController.recognizeText(_:)), "t", [.command, .shift]),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", #selector(CanvasView.undo(_:)), "z"),
            item("Redo", #selector(CanvasView.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(CanvasView.delete(_:)), "", []),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("View", [
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"),
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(EditorWindowController.zoomImageToActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(EditorWindowController.zoomImageToFit(_:)), "9"),
        ]))
        return main
    }
}
