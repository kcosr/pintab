@testable import PinTabCore

/// Shared app identities for tests. Names are arbitrary; only identity matters.
enum App {
    static let a = AppID("com.test.alpha")
    static let b = AppID("com.test.bravo")
    static let c = AppID("com.test.charlie")
    static let d = AppID("com.test.delta")
    static let e = AppID("com.test.echo")
    /// An app that is never pinned (e.g. the frontmost app when switching starts from outside the list).
    static let outsider = AppID("com.test.outsider")
}

extension SwitcherMachine {
    var switchSession: SwitchSession? {
        if case .switching(let session) = phase { return session }
        return nil
    }

    var manageSession: ManageSession? {
        if case .managing(let session) = phase { return session }
        return nil
    }

    var isIdle: Bool { phase == .idle }
}

extension Array where Element == SwitcherEffect {
    var activations: [AppID] {
        compactMap { if case .activate(let id) = $0 { return id } else { return nil } }
    }

    var pinChanges: [(AppID, Bool)] {
        compactMap { if case let .setPinned(id, pinned) = $0 { return (id, pinned) } else { return nil } }
    }
}

/// Convenience for a held shortcut press.
func heldInvoke(_ candidates: [AppID], origin: AppID?, forward: Bool = true) -> SwitcherEvent {
    .invoke(forward: forward, modifiersHeld: true, candidates: candidates, origin: origin)
}

/// Convenience for a press whose modifiers were already released when handled.
func quickInvoke(_ candidates: [AppID], origin: AppID?, forward: Bool = true) -> SwitcherEvent {
    .invoke(forward: forward, modifiersHeld: false, candidates: candidates, origin: origin)
}
