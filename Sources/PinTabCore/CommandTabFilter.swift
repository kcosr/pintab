extension Shortcut {
    /// ⌘Tab: only usable through the event tap, never through Carbon hotkey registration.
    public static let commandTab = Shortcut(keyCode: KeyCode.tab, modifiers: .command)
}

/// What PinTab is doing, as far as the event tap needs to know.
public enum TapPhase: Sendable, Equatable {
    /// Paused, recording a shortcut, or ⌘Tab mode off: pass every event through untouched.
    case suspended
    case idle
    case switching
    case managing
}

public enum TapEventKind: Sendable, Equatable { case keyDown, keyUp, flagsChanged }

public enum TapAction: Sendable, Equatable {
    /// ⌘Tab or ⌘⇧Tab (including key repeat): start or advance the switcher.
    case cycle(forward: Bool)
    /// Any other key pressed during a switching session (Escape, arrows, M, period, Return, …).
    case sessionKey(keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool)
    /// Modifier state changed during a switching session.
    case modifiersChanged(KeyModifiers)
}

public struct TapDecision: Sendable, Equatable {
    /// Whether the event tap drops the event instead of delivering it to the frontmost app.
    public var swallow: Bool
    /// What the app layer should do in response, if anything.
    public var action: TapAction?

    public init(swallow: Bool, action: TapAction?) {
        self.swallow = swallow
        self.action = action
    }

    /// Deliver the event untouched and do nothing.
    public static let pass = TapDecision(swallow: false, action: nil)
}

/// Decides, for each keyboard event seen by the event tap, whether PinTab consumes it.
///
/// - Modifier changes always reach other apps; they are only reported while switching.
/// - The shortcut key with exactly the shortcut's modifiers (Shift optional, meaning reverse) is
///   swallowed whenever PinTab is not suspended. Extra modifiers such as ⌥ or ⌃ pass through, so a
///   Carbon hotkey like ⌥⌘Tab still works.
/// - While switching, every other key is swallowed too, so nothing typed leaks to the app underneath.
/// - A key-up is swallowed exactly when its key-down was, in every phase, so other apps never see
///   an orphan key-up (or a key-down without its key-up).
public struct CommandTabFilter: Sendable {
    public let shortcut: Shortcut
    /// Keys whose key-down was swallowed and whose key-up has not been seen yet.
    private var swallowedKeys: Set<UInt16> = []
    /// Set by handOff() until the shortcut's modifiers are released: for the rest of that hold,
    /// PinTab steps aside so the macOS switcher gets ⌘Tab.
    public private(set) var isHandingOff = false

    public init(shortcut: Shortcut = .commandTab) {
        self.shortcut = shortcut
    }

    public mutating func decide(
        _ kind: TapEventKind, keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool, phase: TapPhase
    ) -> TapDecision {
        if kind == .flagsChanged, isHandingOff, !modifiers.isSuperset(of: shortcut.modifiers) {
            isHandingOff = false // ⌘ released: the next ⌘Tab is PinTab's again
        }
        // While handing off, behave exactly as if suspended (key-up hygiene still applies).
        let phase = isHandingOff ? .suspended : phase
        switch kind {
        case .flagsChanged:
            guard phase == .switching else { return .pass }
            return TapDecision(swallow: false, action: .modifiersChanged(modifiers))
        case .keyUp:
            // Checked before the phase: a key-down swallowed just before suspension still owns its key-up.
            guard swallowedKeys.remove(keyCode) != nil else { return .pass }
            return TapDecision(swallow: true, action: nil)
        case .keyDown:
            return decideKeyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, phase: phase)
        }
    }

    /// Steps aside until the shortcut's modifiers are released, so presses during the current hold
    /// reach the macOS switcher.
    public mutating func handOff() {
        isHandingOff = true
    }

    /// Forgets which key-downs were swallowed and ends any hand-off (for example after the tap is
    /// re-created).
    public mutating func reset() {
        swallowedKeys.removeAll()
        isHandingOff = false
    }

    private mutating func decideKeyDown(
        keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool, phase: TapPhase
    ) -> TapDecision {
        // A fresh press proves any earlier press of this key ended, even if its key-up never reached
        // the tap (secure input can hide it); otherwise the key would look held forever.
        if !isRepeat { swallowedKeys.remove(keyCode) }
        // Auto-repeat of a key whose press was swallowed belongs to that press. Once the session ends
        // (a held Esc cancelled it, or Return committed it), repeats must neither leak into the app
        // underneath nor, for a held Tab, start a new session.
        if isRepeat && swallowedKeys.contains(keyCode) && phase != .switching {
            return TapDecision(swallow: true, action: nil)
        }
        if phase == .suspended { return .pass }
        if keyCode == shortcut.keyCode && modifiers.subtracting(.shift) == shortcut.modifiers {
            return swallow(keyCode, action: .cycle(forward: !modifiers.contains(.shift)))
        }
        if phase == .switching {
            return swallow(keyCode, action: .sessionKey(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat))
        }
        // Idle or managing: the editing panel handles its own keys, and other hotkeys must still fire.
        return .pass
    }

    private mutating func swallow(_ keyCode: UInt16, action: TapAction) -> TapDecision {
        swallowedKeys.insert(keyCode)
        return TapDecision(swallow: true, action: action)
    }
}
