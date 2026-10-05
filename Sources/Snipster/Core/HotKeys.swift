import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, as used for global shortcuts.
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(KeyCombo.relevantModifiers)
    }

    init?(dictionary: [String: Any]) {
        guard let keyCode = dictionary["keyCode"] as? Int, let modifiers = dictionary["modifiers"] as? Int else {
            return nil
        }
        self.init(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    var dictionary: [String: Any] {
        ["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)]
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    /// The key as an NSMenuItem key equivalent, or "" if it has no single character.
    var menuKeyEquivalent: String {
        let name = KeyCombo.keyName(for: keyCode)
        return name.count == 1 ? name.lowercased() : ""
    }

    /// For example "⌃⇧1".
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + KeyCombo.keyName(for: keyCode)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The label printed on the key in the current keyboard layout.
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// System-wide shortcuts through Carbon hot keys, which need no special
/// permissions and consume the key press so it doesn't reach the front app.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Registration {
        let combo: KeyCombo
        let handler: () -> Void
        var reference: EventHotKeyRef?
    }

    private static let signature: OSType = 0x534E_4950  // "SNIP"
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var isSuspended = false

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { HotKeyCenter.shared.registrations[hotKeyID.id]?.handler() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func install(_ combo: KeyCombo, id: UInt32) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: HotKeyCenter.signature, id: id),
            GetEventDispatcherTarget(), 0, &reference)
        return status == noErr ? reference : nil
    }

    /// Registers a shortcut and returns a token for `unregister`, or nil if
    /// the system refused it (typically because another app owns the combo).
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        if !isSuspended {
            reference = install(combo, id: id)
            if reference == nil { return nil }
        }
        registrations[id] = Registration(combo: combo, handler: handler, reference: reference)
        return id
    }

    func unregister(_ id: UInt32) {
        if let reference = registrations.removeValue(forKey: id)?.reference { UnregisterEventHotKey(reference) }
    }

    /// Releases every shortcut so the keys reach the app again, for example
    /// while the user is typing a new shortcut into the settings window.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for (id, registration) in registrations {
            if let reference = registration.reference { UnregisterEventHotKey(reference) }
            registrations[id]?.reference = nil
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for (id, registration) in registrations {
            registrations[id]?.reference = install(registration.combo, id: id)
        }
    }
}
