import Testing
@testable import PinTabCore

@Suite("Selection within a switching session")
struct SelectionTests {
    let order = [App.a, App.b, App.c]

    @Test func forwardFromPinnedOriginSelectsNextEntry() {
        #expect(SwitchOrder.initialSelection(order: order, origin: App.a, forward: true) == App.b)
        #expect(SwitchOrder.initialSelection(order: order, origin: App.b, forward: true) == App.c)
    }

    @Test func reverseFromPinnedOriginSelectsPreviousEntry() {
        #expect(SwitchOrder.initialSelection(order: order, origin: App.c, forward: false) == App.b)
        #expect(SwitchOrder.initialSelection(order: order, origin: App.b, forward: false) == App.a)
    }

    @Test func initialSelectionWrapsInBothDirections() {
        #expect(SwitchOrder.initialSelection(order: order, origin: App.c, forward: true) == App.a)
        #expect(SwitchOrder.initialSelection(order: order, origin: App.a, forward: false) == App.c)
    }

    @Test func forwardFromOutsideSelectsMostRecentPinWithoutSkippingIt() {
        #expect(SwitchOrder.initialSelection(order: order, origin: App.outsider, forward: true) == App.a)
        #expect(SwitchOrder.initialSelection(order: order, origin: nil, forward: true) == App.a)
    }

    @Test func reverseFromOutsideSelectsLastEntry() {
        #expect(SwitchOrder.initialSelection(order: order, origin: App.outsider, forward: false) == App.c)
        #expect(SwitchOrder.initialSelection(order: order, origin: nil, forward: false) == App.c)
    }

    @Test func noCandidatesMeansNoSelection() {
        #expect(SwitchOrder.initialSelection(order: [], origin: App.a, forward: true) == nil)
        #expect(SwitchOrder.initialSelection(order: [], origin: nil, forward: false) == nil)
        var session = SwitchSession(id: 1, order: [], origin: nil, forward: true)
        session.step(forward: true)
        session.step(forward: false)
        #expect(session.selection == nil)
    }

    @Test func singleCandidateIsAlwaysSelected() {
        // Origin is the only candidate: selecting it again is a harmless no-op commit.
        for forward in [true, false] {
            #expect(SwitchOrder.initialSelection(order: [App.a], origin: App.a, forward: forward) == App.a)
            #expect(SwitchOrder.initialSelection(order: [App.a], origin: App.outsider, forward: forward) == App.a)
        }
        var session = SwitchSession(id: 1, order: [App.a], origin: App.outsider, forward: true)
        session.step(forward: true)
        #expect(session.selection == App.a)
        session.step(forward: false)
        #expect(session.selection == App.a)
    }

    @Test func steppingAdvancesAndWrapsBothWays() {
        var session = SwitchSession(id: 1, order: order, origin: App.a, forward: true)
        #expect(session.selection == App.b)
        session.step(forward: true)
        #expect(session.selection == App.c)
        session.step(forward: true)
        #expect(session.selection == App.a)
        session.step(forward: false)
        #expect(session.selection == App.c)
        session.step(forward: false)
        #expect(session.selection == App.b)
    }

    @Test func sessionOrderDropsDuplicateCandidates() {
        let session = SwitchSession(id: 1, order: [App.a, App.b, App.a, App.c, App.b], origin: App.a, forward: true)
        #expect(session.order == [App.a, App.b, App.c])
        #expect(session.selection == App.b)
    }

    @Test func selectIgnoresAppsOutsideTheSession() {
        var session = SwitchSession(id: 1, order: order, origin: App.a, forward: true)
        session.select(App.outsider)
        #expect(session.selection == App.b)
        session.select(App.c)
        #expect(session.selection == App.c)
    }

    @Test func removingUnselectedAppKeepsSelectedIdentity() {
        // Removing an app *before* the selection shifts indexes; the selection must follow identity.
        var session = SwitchSession(id: 1, order: [App.a, App.b, App.c, App.d], origin: App.b, forward: true)
        #expect(session.selection == App.c)
        session.remove(App.a)
        #expect(session.selection == App.c)
        #expect(session.order == [App.b, App.c, App.d])
        session.remove(App.d)
        #expect(session.selection == App.c)
        let before = session
        session.remove(App.outsider)
        #expect(session == before, "removing an app that is not in the session changes nothing")
        session.step(forward: true)
        #expect(session.selection == App.b)
    }

    @Test func removingSelectedAppSelectsTheAppThatTookItsPlace() {
        var session = SwitchSession(id: 1, order: [App.a, App.b, App.c], origin: App.a, forward: true)
        #expect(session.selection == App.b)
        session.remove(App.b)
        #expect(session.selection == App.c)
        #expect(session.order == [App.a, App.c])
    }

    @Test func removingSelectedLastAppWrapsToFirst() {
        var session = SwitchSession(id: 1, order: [App.a, App.b, App.c], origin: App.b, forward: true)
        #expect(session.selection == App.c)
        session.remove(App.c)
        #expect(session.selection == App.a)
    }

    @Test func removingEveryAppLeavesNoSelection() {
        var session = SwitchSession(id: 1, order: [App.a, App.b], origin: App.a, forward: true)
        session.remove(App.b)
        #expect(session.selection == App.a)
        session.remove(App.a)
        #expect(session.order.isEmpty)
        #expect(session.selection == nil)
        session.step(forward: true)
        #expect(session.selection == nil)
    }
}

@Suite("Switch candidates")
struct SwitchOrderCandidateTests {
    @Test func candidatesFollowRecencyAndExcludeNonRunningPins() {
        let result = SwitchOrder.candidates(
            pins: [App.a, App.b, App.c, App.d],
            running: [App.a, App.c, App.d, App.outsider],
            recency: [App.outsider, App.d, App.b, App.a]
        )
        // b is pinned but not running; outsider is running and recent but not pinned.
        #expect(result == [App.d, App.a, App.c])
    }

    @Test func pinsWithoutHistoryFollowInPinOrder() {
        let result = SwitchOrder.candidates(
            pins: [App.d, App.a, App.c, App.b],
            running: [App.a, App.b, App.c, App.d],
            recency: [App.c]
        )
        #expect(result == [App.c, App.d, App.a, App.b])
        let noHistory = SwitchOrder.candidates(pins: [App.c, App.a, App.b], running: [App.a, App.b, App.c], recency: [])
        #expect(noHistory == [App.c, App.a, App.b])
    }

    @Test func duplicatesInPinsAndRecencyAreCollapsed() {
        let result = SwitchOrder.candidates(
            pins: [App.a, App.b, App.a, App.c, App.b],
            running: [App.a, App.b, App.c],
            recency: [App.b, App.b, App.a, App.b]
        )
        #expect(result == [App.b, App.a, App.c])
    }

    @Test func nothingRunningOrNothingPinnedGivesNoCandidates() {
        #expect(SwitchOrder.candidates(pins: [App.a, App.b], running: [], recency: [App.a]).isEmpty)
        #expect(SwitchOrder.candidates(pins: [], running: [App.a, App.b], recency: [App.a, App.b]).isEmpty)
    }
}
