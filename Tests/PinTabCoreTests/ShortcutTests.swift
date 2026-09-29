import Testing
@testable import PinTabCore
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

@Suite("Shortcut validation")
struct ShortcutValidationTests {
    @Test func shiftInBaseModifiersIsRejected() {
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.control, .shift]).validate() == .shiftNotAllowed)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .shift]).validate() == .shiftNotAllowed)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: .shift).validate() == .shiftNotAllowed)
    }

    @Test func optionOnlyOrNoModifiersIsRejected() {
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: .option).validate() == .needsCommandOrControl)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: []).validate() == .needsCommandOrControl)
    }

    @Test(arguments: KeyCode.modifierKeys.sorted())
    func modifierKeyAsMainKeyIsRejected(_ keyCode: UInt16) {
        #expect(Shortcut(keyCode: keyCode, modifiers: .command).validate() == .modifierKeyOnly)
    }

    @Test func escapeIsRejected() {
        #expect(Shortcut(keyCode: KeyCode.escape, modifiers: .command).validate() == .escapeNotAllowed)
        #expect(Shortcut(keyCode: KeyCode.escape, modifiers: [.control, .option]).validate() == .escapeNotAllowed)
    }

    @Test func systemShortcutsAreReserved() {
        let reserved: [(UInt16, String)] = [
            (KeyCode.tab, "the macOS app switcher"),
            (KeyCode.grave, "macOS window cycling"),
            (KeyCode.space, "Spotlight"),
            (KeyCode.q, "Quit in every app"),
            (KeyCode.w, "Close Window in every app"),
        ]
        for (key, name) in reserved {
            #expect(Shortcut(keyCode: key, modifiers: .command).validate() == .reservedBySystem(name))
        }
    }

    @Test func acceptedShortcuts() {
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .option]).validate() == nil)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: .control).validate() == nil)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.control, .option]).validate() == nil)
        #expect(Shortcut(keyCode: KeyCode.grave, modifiers: [.command, .control]).validate() == nil)
    }

    @Test func advisories() {
        let controlTab = Shortcut(keyCode: KeyCode.tab, modifiers: .control).advisory
        #expect(controlTab?.contains("Control-Tab") == true)
        #expect(Shortcut(keyCode: KeyCode.space, modifiers: .control).advisory != nil)
        #expect(Shortcut(keyCode: KeyCode.m, modifiers: .command).advisory != nil)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .option]).advisory?.contains("period") == true)
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.control, .option]).advisory == nil)
    }

}

@Suite("Modifier handling")
struct ModifierTests {
    let optionCommand = Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .option])

    @Test func extraModifiersSuchAsShiftStillCountAsHeld() {
        #expect(optionCommand.baseModifiersHeld(in: [.command, .option]))
        #expect(optionCommand.baseModifiersHeld(in: [.command, .option, .shift]))
        #expect(optionCommand.baseModifiersHeld(in: [.command, .option, .control, .shift]))
        #expect(optionCommand.reverseModifiers == [.command, .option, .shift])
    }

    @Test func releasingAnyRequiredModifierCommits() {
        #expect(!optionCommand.baseModifiersHeld(in: [.command]))
        #expect(!optionCommand.baseModifiersHeld(in: [.option, .shift]))
        #expect(!optionCommand.baseModifiersHeld(in: []))
        #expect(!Shortcut(keyCode: KeyCode.tab, modifiers: .control).baseModifiersHeld(in: .shift))
    }

    @Test func eventFlagsDecodeLogicalModifiersAndIgnoreOthers() {
        #expect(KeyModifiers(eventFlags: 1 << 17) == .shift)
        #expect(KeyModifiers(eventFlags: 1 << 18) == .control)
        #expect(KeyModifiers(eventFlags: 1 << 19) == .option)
        #expect(KeyModifiers(eventFlags: 1 << 20) == .command)
        // Caps Lock (16), numeric pad (21), help (22) and fn (23) are ignored.
        let noise: UInt = (1 << 16) | (1 << 21) | (1 << 22) | (1 << 23)
        #expect(KeyModifiers(eventFlags: noise) == [])
        #expect(KeyModifiers(eventFlags: noise | (1 << 18) | (1 << 20)) == [.control, .command])
        // Left/right device bits (low 16) are ignored, so either Command key reads as the same modifier.
        #expect(KeyModifiers(eventFlags: (1 << 20) | 0x08) == .command)
        #expect(KeyModifiers(eventFlags: (1 << 20) | 0x10) == .command)
    }

    @Test func carbonFlagsRoundTripForEveryCombination() {
        for raw in UInt8(0)..<16 {
            let modifiers = KeyModifiers(rawValue: raw)
            #expect(KeyModifiers(carbonFlags: modifiers.carbonFlags) == modifiers)
        }
        #expect(KeyModifiers.command.carbonFlags == 0x0100)
        #expect(KeyModifiers.shift.carbonFlags == 0x0200)
        #expect(KeyModifiers.option.carbonFlags == 0x0800)
        #expect(KeyModifiers.control.carbonFlags == 0x1000)
        // Caps Lock (alphaLock 0x0400) is ignored.
        #expect(KeyModifiers(carbonFlags: 0x0400 | 0x0100) == .command)
    }

    #if canImport(AppKit)
    @Test func eventFlagBitsMatchAppKit() {
        #expect(KeyModifiers(eventFlags: NSEvent.ModifierFlags.command.rawValue) == .command)
        #expect(KeyModifiers(eventFlags: NSEvent.ModifierFlags.control.rawValue) == .control)
        #expect(KeyModifiers(eventFlags: NSEvent.ModifierFlags.option.rawValue) == .option)
        #expect(KeyModifiers(eventFlags: NSEvent.ModifierFlags.shift.rawValue) == .shift)
        let ignored: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function, .help]
        #expect(KeyModifiers(eventFlags: ignored.rawValue) == [])
        let all: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .capsLock, .function]
        #expect(KeyModifiers(eventFlags: all.rawValue) == [.command, .control, .option, .shift])
    }
    #endif

    #if canImport(Carbon)
    @Test func carbonConstantsMatchTheSDK() {
        #expect(KeyModifiers.command.carbonFlags == UInt32(cmdKey))
        #expect(KeyModifiers.shift.carbonFlags == UInt32(shiftKey))
        #expect(KeyModifiers.option.carbonFlags == UInt32(optionKey))
        #expect(KeyModifiers.control.carbonFlags == UInt32(controlKey))

        #expect(KeyCode.tab == UInt16(kVK_Tab))
        #expect(KeyCode.space == UInt16(kVK_Space))
        #expect(KeyCode.grave == UInt16(kVK_ANSI_Grave))
        #expect(KeyCode.delete == UInt16(kVK_Delete))
        #expect(KeyCode.escape == UInt16(kVK_Escape))
        #expect(KeyCode.returnKey == UInt16(kVK_Return))
        #expect(KeyCode.keypadEnter == UInt16(kVK_ANSI_KeypadEnter))
        #expect(KeyCode.leftArrow == UInt16(kVK_LeftArrow))
        #expect(KeyCode.rightArrow == UInt16(kVK_RightArrow))
        #expect(KeyCode.downArrow == UInt16(kVK_DownArrow))
        #expect(KeyCode.upArrow == UInt16(kVK_UpArrow))
        #expect(KeyCode.m == UInt16(kVK_ANSI_M))
        #expect(KeyCode.q == UInt16(kVK_ANSI_Q))
        #expect(KeyCode.w == UInt16(kVK_ANSI_W))

        let modifierKeys: Set<UInt16> = Set([
            kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
            kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
        ].map { UInt16($0) })
        #expect(KeyCode.modifierKeys == modifierKeys)
    }
    #endif

    @Test func symbolsUseConventionalOrder() {
        let all: KeyModifiers = [.command, .shift, .option, .control]
        #expect(all.symbols == "⌃⌥⇧⌘")
        #expect(KeyModifiers([.command, .option]).symbols == "⌥⌘")
        #expect(KeyModifiers([.command, .control]).symbols == "⌃⌘")
        #expect(KeyModifiers([]).symbols == "")
        #expect(Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .option]).displayString(keyName: "Tab") == "⌥⌘Tab")
    }
}

@Suite struct ReverseConflictTests {
    @Test(arguments: [UInt16(0x14), 0x15, 0x17])
    func commandDigitWhoseShiftVariantIsAScreenshotShortcutIsRejected(keyCode: UInt16) {
        let problem = Shortcut(keyCode: keyCode, modifiers: .command).validate()
        guard case .reservedBySystem = problem else {
            Issue.record("expected a reserved-by-system problem, got \(String(describing: problem))")
            return
        }
    }

    @Test func controlDigitIsStillAllowed() {
        #expect(Shortcut(keyCode: 0x14, modifiers: .control).validate() == nil)
    }
}
