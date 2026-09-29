import AppKit
import PinTabCore
import SwiftUI

/// Click to record; the next key pressed together with modifiers becomes the shortcut.
/// Escape cancels. While recording, PinTab's own hotkeys are suspended by the owner.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let onBegin: () -> Void
    let onEnd: () -> Void
    /// Returns an error message to show, or nil when the shortcut was accepted.
    let onCapture: (Shortcut) -> String?
    let onError: (String?) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        update(button)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        update(button)
    }

    private func update(_ button: RecorderButton) {
        button.shortcut = shortcut
        button.onBegin = onBegin
        button.onEnd = onEnd
        button.onCapture = onCapture
        button.onError = onError
        button.refreshTitle()
    }
}

final class RecorderButton: NSButton {
    var shortcut: Shortcut?
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onCapture: (Shortcut) -> String? = { _ in nil }
    var onError: (String?) -> Void = { _ in }

    private(set) var isRecording = false
    private var liveModifiers: KeyModifiers = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        setAccessibilityLabel("Switcher shortcut")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func refreshTitle() {
        if isRecording {
            title = liveModifiers.isEmpty ? "Type shortcut…" : liveModifiers.symbols + "…"
        } else if let shortcut {
            title = KeyNames.display(shortcut)
        } else {
            title = "Record Shortcut"
        }
        setAccessibilityValue(title)
    }

    @objc private func clicked() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard !isRecording else { return }
        isRecording = true
        liveModifiers = []
        window?.makeFirstResponder(self)
        onError(nil)
        onBegin()
        refreshTitle()
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        refreshTitle()
        onEnd()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags.rawValue)
        if event.keyCode == KeyCode.escape && modifiers.isEmpty {
            stop()
            return
        }
        let candidate = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
        if modifiers.isEmpty {
            onError("Include Command or Control with the key.")
            return // keep recording
        }
        let error = onCapture(candidate)
        onError(error)
        if error == nil { shortcut = candidate }
        stop()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = KeyModifiers(eventFlags: event.modifierFlags.rawValue)
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Switching to another app while recording must not leave PinTab's hotkeys suspended.
    @objc private func windowDidResignKey(_ note: Notification) {
        stop()
    }
}
