import Testing
@testable import PinTabCore

@Suite("Management session")
struct ManageSessionTests {
    // MARK: Layout

    @Test func layoutOrdersPinnedRunningThenOtherRunningThenClosedPins() {
        let items = ManageSession.layout(
            pins: [App.a, App.b, App.c, App.e],
            runningByName: [App.d, App.c, App.outsider, App.a],
            recency: [App.c, App.outsider]
        )
        #expect(items == [
            // Running pins in switcher order: c has history, a follows in pin order.
            ManageItem(id: App.c, isRunning: true),
            ManageItem(id: App.a, isRunning: true),
            // Other running apps in the given name order.
            ManageItem(id: App.d, isRunning: true),
            ManageItem(id: App.outsider, isRunning: true),
            // Closed pins in pin order.
            ManageItem(id: App.b, isRunning: false),
            ManageItem(id: App.e, isRunning: false),
        ])
    }

    @Test func layoutListsEachAppOnceEvenWithDuplicateInput() {
        let items = ManageSession.layout(
            pins: [App.a, App.b, App.a, App.b],
            runningByName: [App.a, App.d, App.d, App.a],
            recency: [App.a, App.a]
        )
        #expect(items.map(\.id) == [App.a, App.d, App.b])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func layoutWithNoPinsShowsAllRunningApps() {
        let items = ManageSession.layout(pins: [], runningByName: [App.b, App.a], recency: [App.a])
        #expect(items == [ManageItem(id: App.b, isRunning: true), ManageItem(id: App.a, isRunning: true)])
    }

    // MARK: Init and focus

    @Test func initDropsDuplicateItemsAndDefaultsFocusToFirstItem() {
        let session = ManageSession(
            items: [ManageItem(id: App.a, isRunning: true), ManageItem(id: App.b, isRunning: true),
                    ManageItem(id: App.a, isRunning: false)],
            pinned: [App.a]
        )
        #expect(session.items.map(\.id) == [App.a, App.b])
        #expect(session.items[0].isRunning)
        #expect(session.focus == App.a)
        #expect(session.pinnedAtStart == [App.a])
    }

    @Test func initialFocusOutsideTheItemsFallsBackToFirst() {
        let items = [ManageItem(id: App.a, isRunning: true), ManageItem(id: App.b, isRunning: true)]
        #expect(ManageSession(items: items, pinned: [], focus: App.b).focus == App.b)
        #expect(ManageSession(items: items, pinned: [], focus: App.outsider).focus == App.a)
        var empty = ManageSession(items: [], pinned: [], focus: App.a)
        #expect(empty.focus == nil)
        empty.moveFocus(by: 1)
        #expect(empty.focus == nil)

        var session = ManageSession(items: items, pinned: [])
        session.setFocus(App.outsider)
        #expect(session.focus == App.a, "focusing an app that is not shown is ignored")
    }

    @Test func moveFocusClampsAtBothEnds() {
        let items = [App.a, App.b, App.c].map { ManageItem(id: $0, isRunning: true) }
        var session = ManageSession(items: items, pinned: [])
        session.moveFocus(by: -1)
        #expect(session.focus == App.a)
        session.moveFocus(by: 1)
        #expect(session.focus == App.b)
        session.moveFocus(by: 10)
        #expect(session.focus == App.c)
        session.moveFocus(by: 1)
        #expect(session.focus == App.c)
        session.moveFocus(by: -100)
        #expect(session.focus == App.a)
    }

    // MARK: Toggling

    @Test func canToggleRules() {
        let session = ManageSession(
            items: [
                ManageItem(id: App.a, isRunning: true),   // pinned, running
                ManageItem(id: App.b, isRunning: true),   // unpinned, running
                ManageItem(id: App.c, isRunning: false),  // pinned, closed
                ManageItem(id: App.d, isRunning: false),  // unpinned, closed
            ],
            pinned: [App.a, App.c]
        )
        #expect(session.canToggle(App.a))
        #expect(session.canToggle(App.b))
        #expect(session.canToggle(App.c), "unpinning is always allowed")
        #expect(!session.canToggle(App.d), "new pins require a running app")
        #expect(!session.canToggle(App.outsider), "apps not shown cannot be toggled")
    }

    @Test func toggleReturnsNewStateOrNilWhenRefused() {
        var session = ManageSession(
            items: [ManageItem(id: App.a, isRunning: true), ManageItem(id: App.d, isRunning: false)],
            pinned: []
        )
        #expect(session.toggle(App.a) == true)
        #expect(session.toggle(App.a) == false)
        #expect(session.toggle(App.d) == nil)
        #expect(session.toggle(App.outsider) == nil)
        #expect(session.pinned.isEmpty)
    }

    @Test func appPinnedDuringSessionThatQuitsCanBeUnpinnedButNotRepinned() {
        var session = ManageSession(items: [ManageItem(id: App.b, isRunning: true)], pinned: [])
        #expect(session.toggle(App.b) == true)
        session.appTerminated(App.b)
        #expect(session.toggle(App.b) == false)
        // It was never pinned before this session and is no longer running: this would be a new pin.
        #expect(session.toggle(App.b) == nil)
    }

    @Test func runningPinThatQuitsCanStillBeReinstatedAfterUnpin() {
        var session = ManageSession(items: [ManageItem(id: App.a, isRunning: true)], pinned: [App.a])
        session.appTerminated(App.a)
        #expect(session.toggle(App.a) == false)
        #expect(session.toggle(App.a) == true)
    }

    // MARK: Catalog changes

    @Test func catalogChangesNeverReorderExistingItems() {
        var session = ManageSession(
            items: [App.a, App.b, App.c].map { ManageItem(id: $0, isRunning: true) },
            pinned: [App.a]
        )
        session.appTerminated(App.b)
        session.appLaunched(App.d)
        session.appLaunched(App.b)
        session.appTerminated(App.outsider)
        session.appLaunched(App.d)
        #expect(session.items.map(\.id) == [App.a, App.b, App.c, App.d])
        #expect(session.items.allSatisfy { $0.isRunning })
    }
}
