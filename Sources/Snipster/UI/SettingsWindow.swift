import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Snipster Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        Activation.bringToFront()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage(Settings.Key.copyAfterCapture) private var copyAfterCapture = true
    @AppStorage(Settings.Key.openEditorAfterCapture) private var openEditorAfterCapture = true
    @AppStorage(Settings.Key.saveAfterCapture) private var saveAfterCapture = false
    @AppStorage(Settings.Key.saveFolder) private var saveFolderPath = ""
    @AppStorage(Settings.Key.showLoupe) private var showLoupe = true
    @AppStorage(Settings.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @StateObject private var login = LoginItemState()

    // `@State` is a macro in recent SDKs whose plugin ships only with Xcode;
    // a plain ObservableObject keeps this buildable with the Command Line Tools.
    final class LoginItemState: ObservableObject {
        @Published var isEnabled = SMAppService.mainApp.status == .enabled
        @Published var error: String?

        func set(_ enabled: Bool) {
            guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                error = nil
            } catch {
                self.error = "Couldn't change the login item: \(error.localizedDescription)"
                isEnabled = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        HotKeyField(action: action).frame(width: 140, height: 24)
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new keys. Delete clears it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("After a capture") {
                Toggle("Copy to clipboard", isOn: $copyAfterCapture)
                Toggle("Open in the editor", isOn: $openEditorAfterCapture)
                Toggle("Save a PNG", isOn: $saveAfterCapture)
                LabeledContent("Save to") {
                    HStack {
                        Text(Settings.shared.saveFolder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .id(saveFolderPath)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }

            Section("General") {
                Toggle("Show the magnifier while selecting", isOn: $showLoupe)
                Toggle("Show Snipster in the menu bar", isOn: $showMenuBarIcon)
                if !showMenuBarIcon {
                    Text("The shortcuts keep working. Open Snipster again to get back to these settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Open Snipster at login", isOn: $login.isEnabled)
                    .onChange(of: login.isEnabled) { _, enabled in login.set(enabled) }
                if let error = login.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path
        }
    }
}

/// A button that records a global shortcut for one capture action.
struct HotKeyField: NSViewRepresentable {
    let action: CaptureAction

    func makeNSView(context: Context) -> HotKeyRecorder { HotKeyRecorder(action: action) }
    func updateNSView(_ nsView: HotKeyRecorder, context: Context) {}
}

final class HotKeyRecorder: NSButton {
    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]
    private let captureAction: CaptureAction
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            // While recording, the existing shortcuts must not fire (or be
            // swallowed before we see them).
            if isRecording { HotKeyCenter.shared.suspend() } else { HotKeyCenter.shared.resume() }
            refresh()
        }
    }

    init(action: CaptureAction) {
        captureAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(toggleRecording)
        toolTip = "Click, then press a shortcut. Delete clears it, Esc cancels."
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        title = isRecording ? "Type shortcut…" : (Settings.shared.combo(for: captureAction)?.displayString ?? "None")
    }

    @objc private func toggleRecording() {
        isRecording.toggle()
        if isRecording { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isRecording = false }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        let key = Int(event.keyCode)
        if key == kVK_Escape, modifiers.isEmpty {
            isRecording = false
        } else if key == kVK_Delete || key == kVK_ForwardDelete, modifiers.isEmpty {
            Settings.shared.setCombo(nil, for: captureAction)
            isRecording = false
        } else if !modifiers.intersection([.command, .control, .option]).isEmpty || HotKeyRecorder.functionKeys.contains(key) {
            // Plain letters would make the keyboard unusable, so insist on a
            // modifier (function keys are fine on their own).
            Settings.shared.setCombo(KeyCombo(keyCode: UInt32(key), modifiers: modifiers), for: captureAction)
            isRecording = false
        } else {
            NSSound.beep()
        }
    }
}
