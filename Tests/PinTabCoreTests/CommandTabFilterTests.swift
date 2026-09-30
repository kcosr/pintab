import Testing
@testable import PinTabCore

/// Left Command, as reported in the key code of a flagsChanged event.
private let commandKey: UInt16 = 0x37
private let activePhases: [TapPhase] = [.idle, .switching, .managing]

extension CommandTabFilter {
    fileprivate mutating func keyDown(
        _ keyCode: UInt16, _ modifiers: KeyModifiers = [], isRepeat: Bool = false, in phase: TapPhase
    ) -> TapDecision {
        decide(.keyDown, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, phase: phase)
    }

    fileprivate mutating func keyUp(_ keyCode: UInt16, _ modifiers: KeyModifiers = [], in phase: TapPhase) -> TapDecision {
        decide(.keyUp, keyCode: keyCode, modifiers: modifiers, isRepeat: false, phase: phase)
    }

    fileprivate mutating func flagsChanged(_ modifiers: KeyModifiers, in phase: TapPhase) -> TapDecision {
        decide(.flagsChanged, keyCode: commandKey, modifiers: modifiers, isRepeat: false, phase: phase)
    }
}

private func swallowed(_ action: TapAction?) -> TapDecision {
    TapDecision(swallow: true, action: action)
}

@Suite("⌘Tab filter: key-down")
struct CommandTabFilterKeyDownTests {
    @Test(arguments: activePhases)
    func commandTabCyclesForwardInEveryActivePhase(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        #expect(filter.keyDown(KeyCode.tab, .command, in: phase) == swallowed(.cycle(forward: true)))
    }

    @Test(arguments: activePhases)
    func commandShiftTabCyclesBackward(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        #expect(filter.keyDown(KeyCode.tab, [.command, .shift], in: phase) == swallowed(.cycle(forward: false)))
    }

    @Test func keyRepeatKeepsCycling() {
        var filter = CommandTabFilter()
        #expect(filter.keyDown(KeyCode.tab, .command, in: .idle) == swallowed(.cycle(forward: true)))
        #expect(filter.keyDown(KeyCode.tab, .command, isRepeat: true, in: .switching) == swallowed(.cycle(forward: true)))
        #expect(
            filter.keyDown(KeyCode.tab, [.command, .shift], isRepeat: true, in: .switching)
                == swallowed(.cycle(forward: false))
        )
    }

    @Test func suspendedPassesEveryKeyDownAndRecordsNothing() {
        var filter = CommandTabFilter()
        #expect(filter.keyDown(KeyCode.tab, .command, in: .suspended) == .pass)
        #expect(filter.keyDown(KeyCode.tab, [.command, .shift], in: .suspended) == .pass)
        #expect(filter.keyDown(KeyCode.escape, in: .suspended) == .pass)
        // Nothing was recorded, so the key-ups pass even once PinTab is active again.
        #expect(filter.keyUp(KeyCode.tab, .command, in: .idle) == .pass)
        #expect(filter.keyUp(KeyCode.escape, in: .switching) == .pass)
    }

    @Test(arguments: [TapPhase.idle, .managing])
    func tabWithOtherModifiersReachesOtherHotkeys(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        // ⌥⌘Tab must still reach its Carbon hotkey; ⌃⌘Tab and plain Tab belong to other apps.
        let others: [KeyModifiers] = [[.command, .option], [.command, .control], [.command, .option, .shift], [], .shift, .control]
        for modifiers in others {
            #expect(filter.keyDown(KeyCode.tab, modifiers, in: phase) == .pass)
            #expect(filter.keyUp(KeyCode.tab, modifiers, in: phase) == .pass)
        }
    }

    @Test func otherCommandShortcutsPassWhenIdle() {
        var filter = CommandTabFilter()
        #expect(filter.keyDown(KeyCode.grave, .command, in: .idle) == .pass)
        #expect(filter.keyDown(KeyCode.space, .command, in: .idle) == .pass)
        #expect(filter.keyDown(KeyCode.q, .command, in: .idle) == .pass)
    }

    @Test func otherKeysAreSessionKeysWhileSwitching() {
        var filter = CommandTabFilter()
        let keys = [KeyCode.escape, KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.m, KeyCode.period, KeyCode.returnKey]
        for key in keys {
            let decision = filter.keyDown(key, .command, in: .switching)
            #expect(decision == swallowed(.sessionKey(keyCode: key, modifiers: .command, isRepeat: false)))
        }
    }

    @Test func sessionKeysReportModifiersAndRepeat() {
        var filter = CommandTabFilter()
        #expect(
            filter.keyDown(KeyCode.rightArrow, [.command, .shift], isRepeat: true, in: .switching)
                == swallowed(.sessionKey(keyCode: KeyCode.rightArrow, modifiers: [.command, .shift], isRepeat: true))
        )
        // Command already released but the session not yet committed: still nothing may leak.
        #expect(
            filter.keyDown(KeyCode.escape, in: .switching)
                == swallowed(.sessionKey(keyCode: KeyCode.escape, modifiers: [], isRepeat: false))
        )
    }

    @Test func tabWithOtherModifiersIsASessionKeyWhileSwitching() {
        var filter = CommandTabFilter()
        #expect(
            filter.keyDown(KeyCode.tab, [.command, .option], in: .switching)
                == swallowed(.sessionKey(keyCode: KeyCode.tab, modifiers: [.command, .option], isRepeat: false))
        )
        #expect(
            filter.keyDown(KeyCode.tab, in: .switching)
                == swallowed(.sessionKey(keyCode: KeyCode.tab, modifiers: [], isRepeat: false))
        )
    }

    @Test(arguments: [TapPhase.idle, .managing])
    func otherKeysPassOutsideASwitchingSession(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        let keys = [KeyCode.escape, KeyCode.leftArrow, KeyCode.downArrow, KeyCode.m, KeyCode.period, KeyCode.returnKey]
        for key in keys {
            #expect(filter.keyDown(key, in: phase) == .pass)
            #expect(filter.keyDown(key, .command, isRepeat: true, in: phase) == .pass)
            #expect(filter.keyUp(key, in: phase) == .pass)
        }
    }
}

@Suite("⌘Tab filter: key-up tracking")
struct CommandTabFilterKeyUpTests {
    @Test(arguments: [TapPhase.suspended, .idle, .switching, .managing])
    func keyUpWithoutASwallowedKeyDownPasses(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        #expect(filter.keyUp(KeyCode.tab, .command, in: phase) == .pass)
        #expect(filter.keyUp(KeyCode.escape, in: phase) == .pass)
    }

    @Test func keyUpIsSwallowedOnceAfterItsKeyDown() {
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == .pass)
    }

    @Test func repeatedKeyDownsNeedOnlyOneKeyUp() {
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        _ = filter.keyDown(KeyCode.tab, .command, isRepeat: true, in: .switching)
        _ = filter.keyDown(KeyCode.tab, .command, isRepeat: true, in: .switching)
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == .pass)
    }

    @Test func keysAreTrackedIndependently() {
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        _ = filter.keyDown(KeyCode.rightArrow, .command, in: .switching)
        #expect(filter.keyUp(KeyCode.escape, .command, in: .switching) == .pass)
        #expect(filter.keyUp(KeyCode.rightArrow, .command, in: .switching) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.rightArrow, .command, in: .switching) == .pass)
    }

    @Test func keyUpMatchesByKeyCodeRegardlessOfModifiers() {
        // Command is released before Tab: the Tab key-up arrives with no modifiers and after the commit.
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        _ = filter.flagsChanged([], in: .switching)
        #expect(filter.keyUp(KeyCode.tab, in: .idle) == swallowed(nil))
    }

    @Test func keyUpAfterTheSessionEndsIsStillSwallowed() {
        // Escape cancels the session on key-down; its key-up arrives once PinTab is idle again.
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.escape, .command, in: .switching)
        #expect(filter.keyUp(KeyCode.escape, .command, in: .idle) == swallowed(nil))
    }

    @Test func noOrphanKeyUpLeaksAcrossSuspension() {
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        _ = filter.keyDown(KeyCode.m, .command, in: .switching)
        // PinTab is paused (or ⌘Tab mode turned off) while both keys are still down.
        #expect(filter.keyUp(KeyCode.tab, .command, in: .suspended) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.m, .command, in: .suspended) == swallowed(nil))
        #expect(filter.keyUp(KeyCode.tab, .command, in: .suspended) == .pass)
    }

    @Test func resetForgetsSwallowedKeyDowns() {
        var filter = CommandTabFilter()
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        _ = filter.keyDown(KeyCode.escape, .command, in: .switching)
        filter.reset()
        #expect(filter.keyUp(KeyCode.tab, .command, in: .idle) == .pass)
        #expect(filter.keyUp(KeyCode.escape, .command, in: .idle) == .pass)
        // Tracking works normally afterwards.
        _ = filter.keyDown(KeyCode.tab, .command, in: .idle)
        #expect(filter.keyUp(KeyCode.tab, .command, in: .switching) == swallowed(nil))
    }
}

@Suite("⌘Tab filter: modifier changes")
struct CommandTabFilterFlagsTests {
    @Test func flagsChangedIsReportedButNotSwallowedWhileSwitching() {
        var filter = CommandTabFilter()
        #expect(filter.flagsChanged([.command, .shift], in: .switching) == TapDecision(
            swallow: false, action: .modifiersChanged([.command, .shift])
        ))
        #expect(filter.flagsChanged([], in: .switching) == TapDecision(swallow: false, action: .modifiersChanged([])))
    }

    @Test(arguments: [TapPhase.suspended, .idle, .managing])
    func flagsChangedPassesSilentlyOutsideASwitchingSession(_ phase: TapPhase) {
        var filter = CommandTabFilter()
        #expect(filter.flagsChanged(.command, in: phase) == .pass)
        #expect(filter.flagsChanged([], in: phase) == .pass)
    }

    @Test func flagsChangedDoesNotAffectKeyUpTracking() {
        var filter = CommandTabFilter()
        _ = filter.flagsChanged(.command, in: .switching)
        #expect(filter.keyUp(commandKey, in: .switching) == .pass)
    }
}

@Suite("⌘Tab filter: shortcut")
struct CommandTabFilterShortcutTests {
    @Test func defaultsToCommandTab() {
        #expect(Shortcut.commandTab == Shortcut(keyCode: KeyCode.tab, modifiers: .command))
        #expect(CommandTabFilter().shortcut == .commandTab)
        // Carbon registration would be refused: ⌘Tab only works through the event tap.
        #expect(Shortcut.commandTab.validate() == .reservedBySystem("the macOS app switcher"))
    }

    @Test func passIsNotSwallowedAndHasNoAction() {
        #expect(TapDecision.pass == TapDecision(swallow: false, action: nil))
    }

    @Test func customShortcutIsHonoured() {
        var filter = CommandTabFilter(shortcut: Shortcut(keyCode: KeyCode.grave, modifiers: [.command, .option]))
        #expect(filter.keyDown(KeyCode.grave, [.command, .option], in: .idle) == swallowed(.cycle(forward: true)))
        #expect(
            filter.keyDown(KeyCode.grave, [.command, .option, .shift], in: .switching)
                == swallowed(.cycle(forward: false))
        )
        #expect(filter.keyUp(KeyCode.grave, [.command, .option], in: .switching) == swallowed(nil))
        // ⌘Tab and plain ⌘` are no longer PinTab's.
        #expect(filter.keyDown(KeyCode.tab, .command, in: .idle) == .pass)
        #expect(filter.keyDown(KeyCode.grave, .command, in: .idle) == .pass)
        #expect(filter.keyDown(KeyCode.tab, .command, in: .managing) == .pass)
    }
}

@Suite("Command-Tab filter: held keys after a session")
struct CommandTabFilterHeldKeyTests {
    @Test func repeatsOfASwallowedKeyDoNotLeakAfterTheSessionEnds() {
        var filter = CommandTabFilter()
        let escape = KeyCode.escape
        #expect(filter.decide(.keyDown, keyCode: escape, modifiers: .command, isRepeat: false, phase: .switching).swallow)
        // Esc cancelled the session; the key is still held and auto-repeats.
        for phase in [TapPhase.idle, .managing, .suspended] {
            let decision = filter.decide(.keyDown, keyCode: escape, modifiers: [], isRepeat: true, phase: phase)
            #expect(decision == TapDecision(swallow: true, action: nil))
        }
        #expect(filter.decide(.keyUp, keyCode: escape, modifiers: [], isRepeat: false, phase: .idle).swallow)
        // After the key-up, the key is ordinary again.
        #expect(filter.decide(.keyDown, keyCode: escape, modifiers: [], isRepeat: true, phase: .idle) == .pass)
    }

    @Test func heldCommandTabRepeatStillCyclesInEveryActivePhase() {
        var filter = CommandTabFilter()
        _ = filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: .command, isRepeat: false, phase: .idle)
        let decision = filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: .command, isRepeat: true, phase: .switching)
        #expect(decision == TapDecision(swallow: true, action: .cycle(forward: true)))
    }
}

@Suite("Command-Tab filter: review fixes")
struct CommandTabFilterReviewTests {
    @Test func heldTabRepeatAfterCancelDoesNotStartANewSession() {
        var filter = CommandTabFilter()
        #expect(filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: .command, isRepeat: false, phase: .idle).action == .cycle(forward: true))
        #expect(filter.decide(.keyDown, keyCode: KeyCode.escape, modifiers: .command, isRepeat: false, phase: .switching).swallow)
        // Esc cancelled; Tab is still held and repeats.
        let repeatAfterCancel = filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: .command, isRepeat: true, phase: .idle)
        #expect(repeatAfterCancel == TapDecision(swallow: true, action: nil))
    }

    @Test func aFreshPressClearsAKeyWhoseKeyUpWasNeverSeen() {
        var filter = CommandTabFilter()
        _ = filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: .command, isRepeat: false, phase: .idle)
        // The Tab key-up was hidden (secure input). Later, a plain Tab press:
        #expect(filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: [], isRepeat: false, phase: .idle) == .pass)
        #expect(filter.decide(.keyDown, keyCode: KeyCode.tab, modifiers: [], isRepeat: true, phase: .idle) == .pass)
        #expect(filter.decide(.keyUp, keyCode: KeyCode.tab, modifiers: [], isRepeat: false, phase: .idle) == .pass)
    }
}
