import Testing
@testable import PinTabCore

@Suite("Recent use tracking")
struct RecencyTests {
    @Test func observedActivationMovesAppToFront() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.a)
        tracker.observedActivation(App.b)
        tracker.observedActivation(App.c)
        #expect(tracker.history == [App.c, App.b, App.a])
        tracker.observedActivation(App.a)
        #expect(tracker.history == [App.a, App.c, App.b])
        tracker.observedActivation(App.a)
        #expect(tracker.history == [App.a, App.c, App.b], "reactivating the front app changes nothing")
    }

    @Test func onlyExplicitObservedActivationsChangeHistory() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.a)
        tracker.observedActivation(App.b)
        let before = tracker.history

        // Reading origin and order must not mutate history.
        _ = tracker.origin(frontmost: App.c, at: 0)
        _ = tracker.order(at: 0)
        // A requested (not yet observed) activation must not be recorded as history either.
        tracker.requestedActivation(App.c, at: 10)
        #expect(tracker.history == before)

        // Highlighting and cancelling in a switching session never touch the tracker.
        var machine = SwitcherMachine()
        let candidates = SwitchOrder.candidates(pins: [App.a, App.b, App.c], running: [App.a, App.b, App.c],
                                                recency: tracker.order(at: 10))
        _ = machine.handle(heldInvoke(candidates, origin: tracker.origin(frontmost: App.b, at: 10)))
        _ = machine.handle(.step(forward: true))
        _ = machine.handle(.point(App.a))
        _ = machine.handle(.cancel)
        #expect(tracker.history == before)
    }

    @Test func provisionalActivationIsOriginAndFrontOfOrderWhilePending() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.b)
        tracker.observedActivation(App.a)
        tracker.requestedActivation(App.b, at: 100)
        #expect(tracker.origin(frontmost: App.a, at: 100.5) == App.b)
        #expect(tracker.order(at: 100.5) == [App.b, App.a])
        #expect(tracker.origin(frontmost: nil, at: 100.5) == App.b)

        // A requested app with no recorded history is still put first.
        tracker.requestedActivation(App.c, at: 200)
        #expect(tracker.order(at: 200.2) == [App.c, App.a, App.b])
    }

    @Test func provisionalActivationExpiresAfterItsLifetime() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.b)
        tracker.observedActivation(App.a)
        tracker.requestedActivation(App.b, at: 100)
        let later = 100 + RecencyTracker.provisionalLifetime + 0.5
        #expect(tracker.origin(frontmost: App.a, at: later) == App.a)
        #expect(tracker.order(at: later) == [App.a, App.b])
        // Timestamps before the request (clock skew) never see it either.
        #expect(tracker.origin(frontmost: App.a, at: 99.5) == App.a)
        #expect(tracker.order(at: 99.5) == [App.a, App.b])
    }

    @Test func observedActivationClearsProvisional() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.a)
        tracker.requestedActivation(App.b, at: 100)
        tracker.observedActivation(App.b)
        #expect(tracker.order(at: 100.2) == [App.b, App.a])
        #expect(tracker.origin(frontmost: App.b, at: 100.2) == App.b)

        // An observed activation of a different app supersedes the pending request.
        tracker.requestedActivation(App.a, at: 200)
        tracker.observedActivation(App.c)
        #expect(tracker.origin(frontmost: App.c, at: 200.2) == App.c)
        #expect(tracker.order(at: 200.2) == [App.c, App.b, App.a])
    }

    @Test func fastTapTapTogglesBetweenTwoPinsBeforeActivationIsObserved() {
        let pins = [App.a, App.b, App.c]
        let running: Set<AppID> = [App.a, App.b, App.c]
        var tracker = RecencyTracker()
        tracker.observedActivation(App.c)
        tracker.observedActivation(App.b)
        tracker.observedActivation(App.a)
        var machine = SwitcherMachine()

        // First tap from A switches to B.
        func tap(at time: Double, frontmost: AppID) -> [SwitcherEffect] {
            let candidates = SwitchOrder.candidates(pins: pins, running: running, recency: tracker.order(at: time))
            let origin = tracker.origin(frontmost: frontmost, at: time)
            return machine.handle(quickInvoke(candidates, origin: origin))
        }
        #expect(tap(at: 0, frontmost: App.a) == [.activate(App.b)])
        tracker.requestedActivation(App.b, at: 0)

        // Second tap arrives before macOS reports B as frontmost: it must go back to A, not to B again.
        #expect(tap(at: 0.2, frontmost: App.a) == [.activate(App.a)])
    }

    @Test func activationOfUnpinnedAppDoesNotAffectCandidates() {
        var tracker = RecencyTracker()
        tracker.observedActivation(App.b)
        tracker.observedActivation(App.a)
        tracker.observedActivation(App.outsider)
        let candidates = SwitchOrder.candidates(pins: [App.a, App.b], running: [App.a, App.b, App.outsider],
                                                recency: tracker.order(at: 0))
        #expect(candidates == [App.a, App.b])
        // Starting from the unpinned app selects the most recently used pin.
        #expect(SwitchOrder.initialSelection(order: candidates, origin: App.outsider, forward: true) == App.a)
    }
}
