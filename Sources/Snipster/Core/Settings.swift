import AppKit

/// The things Snipster can do from a hotkey or the menu bar.
enum CaptureAction: String, CaseIterable, Identifiable {
    case area
    case window
    case fullscreen
    case scrolling
    case recognizeText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Screen"
        case .scrolling: "Scrolling Capture"
        case .recognizeText: "Copy Text from Screen"
        }
    }

    var symbolName: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .fullscreen: "display"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .recognizeText: "text.viewfinder"
        }
    }

    /// Control-Shift-digit: free on a stock macOS and, unlike Option
    /// combinations, doesn't steal characters on non-US keyboard layouts.
    var defaultCombo: KeyCombo {
        let key: Int
        switch self {
        case .area: key = 18        // 1
        case .window: key = 19      // 2
        case .fullscreen: key = 20  // 3
        case .scrolling: key = 21   // 4
        case .recognizeText: key = 23  // 5
        }
        return KeyCombo(keyCode: UInt32(key), modifiers: [.control, .shift])
    }
}

/// User preferences, stored in UserDefaults under the keys in `Settings.Key`
/// (the settings window binds to the same keys with `@AppStorage`).
@MainActor
final class Settings {
    static let shared = Settings()
    static let hotKeysChanged = Notification.Name("SnipsterHotKeysChanged")

    enum Key {
        static let copyAfterCapture = "copyAfterCapture"
        static let openEditorAfterCapture = "openEditorAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let saveFolder = "saveFolder"
        static let showLoupe = "showLoupe"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let decoration = "decoration"
        static let decorateNewCaptures = "decorateNewCaptures"
        static func hotKey(_ action: CaptureAction) -> String { "hotKey.\(action.rawValue)" }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.copyAfterCapture: true,
            Key.openEditorAfterCapture: true,
            Key.saveAfterCapture: false,
            Key.showLoupe: true,
            Key.showMenuBarIcon: true,
        ])
    }

    var copyAfterCapture: Bool { defaults.bool(forKey: Key.copyAfterCapture) }
    var openEditorAfterCapture: Bool { defaults.bool(forKey: Key.openEditorAfterCapture) }
    var saveAfterCapture: Bool { defaults.bool(forKey: Key.saveAfterCapture) }
    var showLoupe: Bool { defaults.bool(forKey: Key.showLoupe) }
    var showMenuBarIcon: Bool { defaults.bool(forKey: Key.showMenuBarIcon) }

    var saveFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.saveFolder), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.saveFolder) }
    }

    /// The window frame and backdrop last chosen in the editor.
    var decoration: Decoration {
        get { defaults.dictionary(forKey: Key.decoration).map(Decoration.init(dictionary:)) ?? Decoration() }
        set { defaults.set(newValue.dictionary, forKey: Key.decoration) }
    }

    /// Whether new area and window captures start out with that decoration.
    var decorateNewCaptures: Bool {
        get { defaults.bool(forKey: Key.decorateNewCaptures) }
        set { defaults.set(newValue, forKey: Key.decorateNewCaptures) }
    }

    /// The shortcut for an action; nil when the user cleared it.
    func combo(for action: CaptureAction) -> KeyCombo? {
        guard let stored = defaults.dictionary(forKey: Key.hotKey(action)) else { return action.defaultCombo }
        return KeyCombo(dictionary: stored)
    }

    func setCombo(_ combo: KeyCombo?, for action: CaptureAction) {
        // An empty dictionary records "explicitly none", as opposed to "use the default".
        defaults.set(combo?.dictionary ?? [:], forKey: Key.hotKey(action))
        NotificationCenter.default.post(name: Settings.hotKeysChanged, object: nil)
    }
}
