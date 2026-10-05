import AppKit

/// Bringing Snipster to the front from the background.
///
/// macOS 14 made activation cooperative: `NSApp.activate()` is only honoured
/// when the system thinks the user just interacted with the app, and it does
/// not count a global shortcut. An editor that opens behind the window you
/// were working in is useless, so this uses the older call that still takes
/// focus unconditionally.
@MainActor
enum Activation {
    static func bringToFront() {
        (NSApp as ForcefulActivation).activateIgnoringOtherApps()
    }
}

/// Routes the call through a protocol so the deliberate use of a deprecated
/// API doesn't warn at every call site.
private protocol ForcefulActivation {
    func activateIgnoringOtherApps()
}

extension NSApplication: ForcefulActivation {
    @available(macOS, deprecated: 14.0)
    fileprivate func activateIgnoringOtherApps() {
        activate(ignoringOtherApps: true)
    }
}
