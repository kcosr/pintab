import AppKit
import Carbon.HIToolbox
import PinTabCore

/// Registers the switcher shortcut (forward and Shift-reverse) with the Carbon hotkey API.
/// No Accessibility or Input Monitoring permission is involved.
final class HotKeys {
    static let shared = HotKeys()

    /// Called on the main thread for each press.
    var onPress: ((_ forward: Bool) -> Void)?

    private(set) var registered: Shortcut?
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []

    private static let signature: OSType = 0x5054_4142 // 'PTAB'
    private static let forwardID: UInt32 = 1
    private static let reverseID: UInt32 = 2

    enum RegistrationError: Error {
        case usedBySystem
        case usedByAnotherApp
        case failed(OSStatus)

        var message: String {
            switch self {
            case .usedBySystem:
                return "macOS already uses this shortcut (see System Settings › Keyboard › Keyboard Shortcuts)."
            case .usedByAnotherApp:
                return "Another app has reserved this shortcut."
            case .failed(let status):
                return "macOS could not register this shortcut (error \(status))."
            }
        }
    }

    private init() {}

    func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application-target hotkey events on the main thread.
            MainActor.assumeIsolated {
                HotKeys.shared.onPress?(hotKeyID.id == HotKeys.forwardID)
            }
            return noErr
        }, 1, &spec, nil, &handler)
        if status != noErr { Log.input.error("InstallEventHandler failed: \(status)") }
    }

    /// Registers both directions or neither. On failure nothing is left registered.
    func register(_ shortcut: Shortcut) throws(RegistrationError) {
        unregister()
        if Self.isSystemShortcut(shortcut) { throw .usedBySystem }
        do {
            try add(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: Self.forwardID)
            try add(keyCode: shortcut.keyCode, modifiers: shortcut.reverseModifiers, id: Self.reverseID)
        } catch {
            unregister()
            throw error
        }
        registered = shortcut
        Log.input.notice("Registered hotkey keyCode=\(shortcut.keyCode) modifiers=\(shortcut.modifiers.symbols, privacy: .public)")
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        if !refs.isEmpty { Log.input.notice("Unregistered hotkeys") }
        refs = []
        registered = nil
    }

    private func add(keyCode: UInt16, modifiers: KeyModifiers, id: UInt32) throws(RegistrationError) {
        var ref: EventHotKeyRef?
        // Exclusive registration fails if any other registration of this combination exists, which
        // doubles as a conflict check. While PinTab holds it, other apps' registrations stay silent.
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers.carbonFlags,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            throw status == OSStatus(eventHotKeyExistsErr) ? .usedByAnotherApp : .failed(status)
        }
        refs.append(ref)
    }

    /// Whether an enabled macOS symbolic hotkey (Spotlight, screenshots, Mission Control, …)
    /// uses either direction of the shortcut. These register without error but never fire.
    static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let modifierMask = KeyModifiers([.command, .control, .option, .shift]).carbonFlags
        let wanted = [shortcut.modifiers.carbonFlags, shortcut.reverseModifiers.carbonFlags]
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code == shortcut.keyCode
            else { continue }
            if wanted.contains(modifiers & modifierMask) { return true }
        }
        return false
    }
}

/// Human-readable key labels for the current keyboard layout.
enum KeyNames {
    private static let special: [UInt16: String] = [
        KeyCode.tab: "Tab", KeyCode.space: "Space", KeyCode.returnKey: "Return", KeyCode.escape: "Esc",
        KeyCode.delete: "Delete", KeyCode.keypadEnter: "Enter",
        KeyCode.leftArrow: "←", KeyCode.rightArrow: "→", KeyCode.downArrow: "↓", KeyCode.upArrow: "↑",
        0x75: "⌦", 0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    static func name(for keyCode: UInt16) -> String {
        if let name = special[keyCode] { return name }
        return translated(keyCode) ?? "Key \(keyCode)"
    }

    static func display(_ shortcut: Shortcut) -> String {
        shortcut.displayString(keyName: name(for: shortcut.keyCode))
    }

    private static func translated(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                        characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }
}
