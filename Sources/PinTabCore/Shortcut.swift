/// Logical modifier keys. Left and right variants are deliberately indistinguishable.
public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    private static let known: KeyModifiers = [.command, .control, .option, .shift]

    /// Decoding drops unknown bits, so corrupted preferences cannot smuggle a reserved
    /// shortcut past validation (validation compares exactly; Carbon ignores unknown bits).
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(UInt8.self)
        self = KeyModifiers(rawValue: raw).intersection(Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // NSEvent.ModifierFlags device-independent bits. Caps Lock, fn and numeric-pad bits are ignored.
    private static let eventShift: UInt = 1 << 17
    private static let eventControl: UInt = 1 << 18
    private static let eventOption: UInt = 1 << 19
    private static let eventCommand: UInt = 1 << 20

    // Carbon modifier masks (cmdKey, shiftKey, optionKey, controlKey).
    private static let carbonCommand: UInt32 = 0x0100
    private static let carbonShift: UInt32 = 0x0200
    private static let carbonOption: UInt32 = 0x0800
    private static let carbonControl: UInt32 = 0x1000

    /// Builds modifiers from raw `NSEvent.ModifierFlags` (or `CGEventFlags`, which share these bits).
    public init(eventFlags raw: UInt) {
        var result: KeyModifiers = []
        if raw & Self.eventCommand != 0 { result.insert(.command) }
        if raw & Self.eventControl != 0 { result.insert(.control) }
        if raw & Self.eventOption != 0 { result.insert(.option) }
        if raw & Self.eventShift != 0 { result.insert(.shift) }
        self = result
    }

    public init(carbonFlags raw: UInt32) {
        var result: KeyModifiers = []
        if raw & Self.carbonCommand != 0 { result.insert(.command) }
        if raw & Self.carbonControl != 0 { result.insert(.control) }
        if raw & Self.carbonOption != 0 { result.insert(.option) }
        if raw & Self.carbonShift != 0 { result.insert(.shift) }
        self = result
    }

    public var carbonFlags: UInt32 {
        var raw: UInt32 = 0
        if contains(.command) { raw |= Self.carbonCommand }
        if contains(.control) { raw |= Self.carbonControl }
        if contains(.option) { raw |= Self.carbonOption }
        if contains(.shift) { raw |= Self.carbonShift }
        return raw
    }

    /// Symbols in the conventional macOS order: ⌃⌥⇧⌘.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// Virtual key codes PinTab needs by name (values from Carbon's kVK constants).
public enum KeyCode {
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let grave: UInt16 = 0x32
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let returnKey: UInt16 = 0x24
    public static let keypadEnter: UInt16 = 0x4C
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
    public static let m: UInt16 = 0x2E
    public static let p: UInt16 = 0x23
    public static let s: UInt16 = 0x01
    public static let period: UInt16 = 0x2F
    public static let q: UInt16 = 0x0C
    public static let w: UInt16 = 0x0D

    /// Key codes of the modifier keys themselves, which cannot be the main key of a shortcut.
    public static let modifierKeys: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
}

/// A switcher shortcut: a main key plus base modifiers. Shift is reserved for reverse cycling.
public struct Shortcut: Hashable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Modifiers of the reverse-cycling registration.
    public var reverseModifiers: KeyModifiers { modifiers.union(.shift) }

    /// Whether every required base modifier is still held. Releasing any one of them commits.
    /// Extra modifiers (such as Shift) do not matter.
    public func baseModifiersHeld(in current: KeyModifiers) -> Bool {
        current.isSuperset(of: modifiers)
    }

    public func displayString(keyName: String) -> String {
        modifiers.symbols + keyName
    }

    /// Rejects shortcuts that cannot work as a hold-and-release switcher, or that macOS keeps for itself.
    /// System-wide conflicts beyond this fixed list are detected at registration time.
    public func validate() -> ShortcutProblem? {
        if KeyCode.modifierKeys.contains(keyCode) { return .modifierKeyOnly }
        if modifiers.contains(.shift) { return .shiftNotAllowed }
        if !modifiers.contains(.command) && !modifiers.contains(.control) { return .needsCommandOrControl }
        if keyCode == KeyCode.escape { return .escapeNotAllowed }
        for reserved in Self.reservedBySystem where reserved.keyCode == keyCode {
            if reserved.modifiers == modifiers || reserved.modifiers == reverseModifiers {
                return .reservedBySystem(reserved.name)
            }
        }
        return nil
    }

    /// A non-blocking caution for shortcuts that take over common in-app commands.
    public var advisory: String? {
        if modifiers.isSuperset(of: [.command, .option]) {
            return "macOS uses ⌘⌥Esc for Force Quit, so press . (period) instead of Esc to cancel the switcher."
        }
        if keyCode == KeyCode.tab && modifiers == .control {
            return "While PinTab is running, Control-Tab no longer switches tabs inside apps."
        }
        if modifiers == .command || modifiers == .control {
            return "PinTab takes over this shortcut in every app while it is running."
        }
        return nil
    }

    private static let reservedBySystem: [(keyCode: UInt16, modifiers: KeyModifiers, name: String)] = [
        (KeyCode.tab, .command, "the macOS app switcher"),
        (KeyCode.grave, .command, "macOS window cycling"),
        (KeyCode.space, .command, "Spotlight"),
        (KeyCode.q, .command, "Quit in every app"),
        (KeyCode.w, .command, "Close Window in every app"),
        // Reverse cycling adds Shift, so these collide with the screenshot shortcuts.
        (0x14, [.command, .shift], "macOS screenshots (⇧⌘3)"),
        (0x15, [.command, .shift], "macOS screenshots (⇧⌘4)"),
        (0x17, [.command, .shift], "macOS screenshots (⇧⌘5)"),
    ]
}

public enum ShortcutProblem: Error, Hashable, Sendable {
    case modifierKeyOnly
    case shiftNotAllowed
    case needsCommandOrControl
    case escapeNotAllowed
    case reservedBySystem(String)

    public var message: String {
        switch self {
        case .modifierKeyOnly:
            return "Press a key together with the modifiers."
        case .shiftNotAllowed:
            return "Shift is reserved for switching backwards. Use Command or Control, optionally with Option."
        case .needsCommandOrControl:
            return "Include Command or Control. Shortcuts using only Option may not be delivered by macOS."
        case .escapeNotAllowed:
            return "Escape cancels the switcher, so it cannot start it."
        case .reservedBySystem(let name):
            return "This shortcut is used by \(name)."
        }
    }
}
