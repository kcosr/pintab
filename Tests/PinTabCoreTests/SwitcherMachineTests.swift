import Testing
@testable import PinTabCore

@Suite("Switcher state machine: switching")
struct SwitcherMachineSwitchingTests {
    let candidates = [App.a, App.b, App.c]

    // MARK: Quick press

    @Test func quickPressCommitsImmediatelyWithoutShowingThePanel() {
        var machine = SwitcherMachine()
        let effects = machine.handle(quickInvoke(candidates, origin: App.a))
        #expect(effects == [.activate(App.b)])
        #expect(!effects.contains(.show))
        #expect(machine.isIdle)
        // The release that follows the quick press arrives late and must not commit again.
        #expect(machine.handle(.modifiersReleased) == [])
    }

    @Test func quickPressFromOutsideActivatesMostRecentPin() {
        var machine = SwitcherMachine()
        #expect(machine.handle(quickInvoke(candidates, origin: App.outsider)) == [.activate(App.a)])
        #expect(machine.handle(quickInvoke(candidates, origin: App.outsider, forward: false)) == [.activate(App.c)])
    }

    @Test func quickPressWithNoCandidatesBeepsAndStaysIdle() {
        var machine = SwitcherMachine()
        #expect(machine.handle(quickInvoke([], origin: App.outsider)) == [.beep])
        #expect(machine.isIdle)
    }

    // MARK: Held press

    @Test func heldPressShowsPanelWithInitialSelection() {
        var machine = SwitcherMachine()
        let effects = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(effects == [.show])
        #expect(effects.activations.isEmpty)
        #expect(machine.switchSession?.selection == App.b)
        #expect(machine.switchSession?.origin == App.a)
    }

    @Test func heldPressWithNoCandidatesShowsEmptyStateAndReleaseActivatesNothing() {
        var machine = SwitcherMachine()
        #expect(machine.handle(heldInvoke([], origin: App.outsider)) == [.show])
        #expect(machine.switchSession?.selection == nil)
        #expect(machine.handle(.modifiersReleased) == [.hide])
        #expect(machine.isIdle)
    }

    @Test func repeatedInvokeAdvancesAndWraps() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.handle(heldInvoke(candidates, origin: App.a)) == [.show])
        #expect(machine.switchSession?.selection == App.c)
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.switchSession?.selection == App.a)
    }

    @Test func shiftInvokeMovesBackward() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.switchSession?.selection == App.b)
        _ = machine.handle(heldInvoke(candidates, origin: App.a, forward: false))
        #expect(machine.switchSession?.selection == App.a)
        _ = machine.handle(heldInvoke(candidates, origin: App.a, forward: false))
        #expect(machine.switchSession?.selection == App.c)
    }

    @Test func arrowStepsMoveSelectionWithoutActivating() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.handle(.step(forward: true)) == [.show])
        #expect(machine.switchSession?.selection == App.c)
        #expect(machine.handle(.step(forward: false)) == [.show])
        #expect(machine.switchSession?.selection == App.b)
    }

    @Test func invokeWhoseModifiersAreAlreadyReleasedStepsThenCommits() {
        // Second press arrives after the base modifier was released: it is a complete switch.
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.handle(quickInvoke(candidates, origin: App.a)) == [.hide, .activate(App.c)])
        #expect(machine.isIdle)
    }

    // MARK: Commit and cancel

    @Test func releasingModifiersCommitsSelectedAppAndGoesIdle() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.handle(.modifiersReleased) == [.hide, .activate(App.c)])
        #expect(machine.isIdle)
        #expect(machine.sessionID == nil)
    }

    @Test func lateEventsAfterCommitCannotCommitAgain() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let first = machine.handle(.modifiersReleased)
        #expect(first.activations == [App.b])
        let late: [SwitcherEvent] = [
            .modifiersReleased, .click(App.c), .click(App.b), .point(App.c), .step(forward: true),
            .cancel, .focusLost, .done, .toggleFocused, .moveFocus(1),
            .appTerminated(App.b), .appLaunched(App.d),
        ]
        for event in late {
            #expect(machine.handle(event) == [], "late \(event) should be ignored")
            #expect(machine.isIdle)
        }
    }

    @Test(arguments: [SwitcherEvent.cancel, .focusLost])
    func cancelAndFocusLossHideWithoutActivating(_ event: SwitcherEvent) {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        _ = machine.handle(.step(forward: true))
        #expect(machine.handle(event) == [.hide])
        #expect(machine.isIdle)
        // A release arriving after the cancel must not activate the highlighted app.
        #expect(machine.handle(.modifiersReleased) == [])
    }

    // MARK: Pointer

    @Test func pointingChangesSelectionButNeverActivates() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let effects = machine.handle(.point(App.c))
        #expect(effects == [.show])
        #expect(machine.switchSession?.selection == App.c)
        // Pointing at the already selected app, or at something not in the session, is a no-op.
        #expect(machine.handle(.point(App.c)) == [])
        #expect(machine.handle(.point(App.outsider)) == [])
        #expect(machine.switchSession?.selection == App.c)
        // The pointed-at app is what a release commits.
        #expect(machine.handle(.modifiersReleased) == [.hide, .activate(App.c)])
    }

    @Test func clickingAnAppCommitsThatApp() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.switchSession?.selection == App.b)
        #expect(machine.handle(.click(App.outsider)) == [], "a click on something outside the session is ignored")
        #expect(machine.handle(.click(App.a)) == [.hide, .activate(App.a)])
        #expect(machine.isIdle)
        #expect(machine.handle(.modifiersReleased) == [])
    }

    // MARK: Catalog changes

    @Test func terminatedAppIsRemovedAndSelectedIdentityIsPreserved() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke([App.a, App.b, App.c, App.d], origin: App.b))
        #expect(machine.switchSession?.selection == App.c)
        #expect(machine.handle(.appTerminated(App.a)) == [.show])
        #expect(machine.switchSession?.order == [App.b, App.c, App.d])
        #expect(machine.switchSession?.selection == App.c)
        #expect(machine.handle(.modifiersReleased) == [.hide, .activate(App.c)])
    }

    @Test func terminatedSelectedAppIsNeverActivated() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        _ = machine.handle(.appTerminated(App.b))
        #expect(machine.switchSession?.selection == App.c)
        let effects = machine.handle(.modifiersReleased)
        #expect(!effects.activations.contains(App.b))
        #expect(effects == [.hide, .activate(App.c)])
    }

    @Test func allCandidatesTerminatingLeavesNothingToActivate() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke([App.a, App.b], origin: App.a))
        _ = machine.handle(.appTerminated(App.a))
        _ = machine.handle(.appTerminated(App.b))
        #expect(machine.switchSession?.order == [])
        #expect(machine.handle(.modifiersReleased) == [.hide])
    }

    @Test func launchedAppIsIgnoredWhileSwitching() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let before = machine.phase
        #expect(machine.handle(.appLaunched(App.d)) == [])
        #expect(machine.phase == before)
    }

    @Test func sessionOrderStaysFrozenWhenLaterInvokesCarryDifferentCandidates() {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke([App.a, App.b, App.c], origin: App.a))
        // Recency changed underneath (e.g. an activation notification), and the app layer rebuilt candidates.
        _ = machine.handle(heldInvoke([App.c, App.d, App.a, App.b], origin: App.c))
        #expect(machine.switchSession?.order == [App.a, App.b, App.c])
        #expect(machine.switchSession?.origin == App.a)
        #expect(machine.switchSession?.selection == App.c)
    }

    // MARK: Session identity

    @Test func eachSwitchingSessionGetsANewIdentifier() throws {
        var machine = SwitcherMachine()
        #expect(machine.sessionID == nil)
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let first = try #require(machine.sessionID)
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        #expect(machine.sessionID == first, "repeated presses stay in the same session")
        _ = machine.handle(.cancel)
        #expect(machine.sessionID == nil)

        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let second = try #require(machine.sessionID)
        #expect(second > first)
        _ = machine.handle(.modifiersReleased)

        _ = machine.handle(quickInvoke(candidates, origin: App.a))
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        let third = try #require(machine.sessionID)
        #expect(third > second)
    }
}

@Suite("Switcher state machine: management")
struct SwitcherMachineManagingTests {
    let candidates = [App.a, App.b, App.c]
    let items = [
        ManageItem(id: App.a, isRunning: true),
        ManageItem(id: App.b, isRunning: true),
        ManageItem(id: App.c, isRunning: true),
        ManageItem(id: App.d, isRunning: true),
        ManageItem(id: App.e, isRunning: false),
    ]
    let pinned: Set<AppID> = [App.a, App.b, App.c, App.e]

    func managingFromSwitch() -> SwitcherMachine {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        _ = machine.handle(.openManage(items: items, pinned: pinned))
        return machine
    }

    @Test func openingManageFromSwitchingEntersManagementFocusedOnSelection() throws {
        var machine = SwitcherMachine()
        _ = machine.handle(heldInvoke(candidates, origin: App.a))
        _ = machine.handle(.step(forward: true))
        #expect(machine.handle(.openManage(items: items, pinned: pinned)) == [.show])
        let session = try #require(machine.manageSession)
        #expect(session.focus == App.c)
        #expect(session.pinned == pinned)
        #expect(machine.sessionID == nil)
    }

    @Test func releasingModifiersWhileManagingNeverSwitchesOrCloses() {
        var machine = managingFromSwitch()
        let before = machine.phase
        #expect(machine.handle(.modifiersReleased) == [])
        #expect(machine.handle(.modifiersReleased) == [])
        #expect(machine.phase == before)
    }

    @Test func openingManageFromMenuBarWhileIdle() {
        var machine = SwitcherMachine()
        #expect(machine.handle(.openManage(items: items, pinned: pinned)) == [.show])
        #expect(machine.manageSession?.focus == App.a)
        #expect(machine.handle(.modifiersReleased) == [])
        #expect(machine.manageSession != nil)
    }

    @Test func invokeWhileManagingOnlyBringsPanelForward() {
        var machine = managingFromSwitch()
        let before = machine.phase
        #expect(machine.handle(heldInvoke([App.d, App.a], origin: App.d)) == [.show])
        #expect(machine.handle(quickInvoke([App.d, App.a], origin: App.d)) == [.show])
        #expect(machine.handle(.openManage(items: [], pinned: [])) == [.show])
        #expect(machine.phase == before)
    }

    @Test(arguments: [SwitcherEvent.done, .cancel, .focusLost])
    func doneCancelAndFocusLossCloseManagementWithoutActivating(_ event: SwitcherEvent) {
        var machine = managingFromSwitch()
        _ = machine.handle(.click(App.d))
        #expect(machine.handle(event) == [.hide])
        #expect(machine.isIdle)
        #expect(machine.handle(.modifiersReleased) == [])
    }

    @Test func eachToggleEmitsExactlyOneSetPinned() {
        var machine = managingFromSwitch()
        let pin = machine.handle(.click(App.d))
        #expect(pin == [.setPinned(App.d, true), .show])
        #expect(machine.manageSession?.focus == App.d, "clicking a tile also focuses it")
        let unpin = machine.handle(.click(App.a))
        #expect(unpin == [.setPinned(App.a, false), .show])
        let repin = machine.handle(.click(App.a))
        #expect(repin == [.setPinned(App.a, true), .show])
        #expect(machine.manageSession?.pinned == [App.a, App.b, App.c, App.d, App.e])
    }

    @Test func toggleFocusedUsesKeyboardFocus() {
        var machine = managingFromSwitch()
        #expect(machine.manageSession?.focus == App.b)
        _ = machine.handle(.moveFocus(2))
        #expect(machine.manageSession?.focus == App.d)
        #expect(machine.handle(.toggleFocused) == [.setPinned(App.d, true), .show])
        #expect(machine.handle(.toggleFocused) == [.setPinned(App.d, false), .show])
    }

    @Test func managementNeverActivatesAnything() {
        var machine = managingFromSwitch()
        let events: [SwitcherEvent] = [
            .point(App.c), .click(App.c), .click(App.d), .step(forward: true), .step(forward: false),
            .moveFocus(3), .toggleFocused, .appTerminated(App.b), .appLaunched(App.outsider),
            .modifiersReleased, heldInvoke(candidates, origin: App.a), .click(App.outsider), .done,
        ]
        for event in events {
            #expect(machine.handle(event).activations.isEmpty, "\(event) must not activate")
        }
    }

    @Test func pointingMovesFocusOnly() {
        var machine = managingFromSwitch()
        #expect(machine.handle(.point(App.d)) == [.show])
        #expect(machine.manageSession?.focus == App.d)
        #expect(machine.handle(.point(App.d)) == [])
        #expect(machine.manageSession?.pinned == pinned)
    }

    @Test func pinningANonRunningUnpinnedAppIsRefused() {
        var machine = SwitcherMachine()
        let items = [ManageItem(id: App.a, isRunning: true), ManageItem(id: App.e, isRunning: false)]
        _ = machine.handle(.openManage(items: items, pinned: [App.a]))
        let effects = machine.handle(.click(App.e))
        #expect(effects.pinChanges.isEmpty)
        #expect(effects == [.show])
        #expect(machine.manageSession?.pinned == [App.a])
    }

    @Test func undoingAnUnpinOfAClosedAppIsAllowedWithinTheSession() {
        var machine = managingFromSwitch()
        #expect(machine.handle(.click(App.e)) == [.setPinned(App.e, false), .show])
        #expect(machine.handle(.click(App.e)) == [.setPinned(App.e, true), .show])
        #expect(machine.manageSession?.pinned.contains(App.e) == true)
    }

    @Test func launchedAppIsAppendedWhileManaging() {
        var machine = managingFromSwitch()
        #expect(machine.handle(.appLaunched(App.outsider)) == [.show])
        #expect(machine.manageSession?.items.map(\.id) == [App.a, App.b, App.c, App.d, App.e, App.outsider])
        // Newly launched apps can be pinned.
        #expect(machine.handle(.click(App.outsider)) == [.setPinned(App.outsider, true), .show])
        // A closed pin that relaunches becomes running in place rather than being appended again.
        _ = machine.handle(.appLaunched(App.e))
        #expect(machine.manageSession?.items.map(\.id) == [App.a, App.b, App.c, App.d, App.e, App.outsider])
        #expect(machine.manageSession?.items[4] == ManageItem(id: App.e, isRunning: true))
    }

    @Test func togglingAndTerminationKeepTileOrderStable() {
        var machine = managingFromSwitch()
        let ids = machine.manageSession?.items.map(\.id)
        _ = machine.handle(.click(App.d))
        _ = machine.handle(.click(App.a))
        _ = machine.handle(.click(App.e))
        #expect(machine.handle(.appTerminated(App.b)) == [.show])
        #expect(machine.manageSession?.items.map(\.id) == ids)
        #expect(machine.manageSession?.items[1] == ManageItem(id: App.b, isRunning: false), "terminated tile stays, dimmed")
    }
}
