/// One hold-to-switch session. The order is frozen for the session's lifetime; only terminated
/// apps are removed. Selection is an app identity, never an index.
public struct SwitchSession: Sendable, Equatable {
    public let id: Int
    public let origin: AppID?
    public private(set) var order: [AppID]
    public private(set) var selection: AppID?

    public init(id: Int, order: [AppID], origin: AppID?, forward: Bool) {
        self.id = id
        self.origin = origin
        self.order = SwitchOrder.unique(order)
        self.selection = SwitchOrder.initialSelection(order: self.order, origin: origin, forward: forward)
    }

    public mutating func step(forward: Bool) {
        guard !order.isEmpty else { return }
        guard let selection, let index = order.firstIndex(of: selection) else {
            self.selection = forward ? order.first : order.last
            return
        }
        self.selection = order[SwitchOrder.wrap(index + (forward ? 1 : -1), count: order.count)]
    }

    public mutating func select(_ id: AppID) {
        if order.contains(id) { selection = id }
    }

    /// Removes a terminated app. If it was selected, the app that took its place becomes selected.
    public mutating func remove(_ id: AppID) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        if selection == id {
            selection = order.isEmpty ? nil : order[index % order.count]
        }
    }
}

public struct ManageItem: Sendable, Equatable, Identifiable {
    public let id: AppID
    public var isRunning: Bool

    public init(id: AppID, isRunning: Bool) {
        self.id = id
        self.isRunning = isRunning
    }
}

/// The persistent editing panel. Item positions never change while it is open: pinning does not
/// move tiles, terminated apps stay in place (dimmed), and launched apps are appended.
public struct ManageSession: Sendable, Equatable {
    public private(set) var items: [ManageItem]
    public private(set) var pinned: Set<AppID>
    public private(set) var focus: AppID?
    /// Pins that existed when editing began. These can be re-pinned (undo) even if the app has quit.
    public let pinnedAtStart: Set<AppID>

    public init(items: [ManageItem], pinned: Set<AppID>, focus: AppID? = nil) {
        var seen = Set<AppID>()
        self.items = items.filter { seen.insert($0.id).inserted }
        self.pinned = pinned
        self.pinnedAtStart = pinned
        let ids = self.items.map(\.id)
        self.focus = focus.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    /// Stable layout: running pinned apps in switcher order, then other running apps by name,
    /// then pins whose apps are not running (pin order). `running` must already be sorted by name.
    public static func layout(pins: [AppID], runningByName: [AppID], recency: [AppID]) -> [ManageItem] {
        let runningSet = Set(runningByName)
        let pinSet = Set(pins)
        let pinnedRunning = SwitchOrder.candidates(pins: pins, running: runningSet, recency: recency)
        let others = SwitchOrder.unique(runningByName).filter { !pinSet.contains($0) }
        let closed = SwitchOrder.unique(pins).filter { !runningSet.contains($0) }
        return pinnedRunning.map { ManageItem(id: $0, isRunning: true) }
            + others.map { ManageItem(id: $0, isRunning: true) }
            + closed.map { ManageItem(id: $0, isRunning: false) }
    }

    /// Unpinning is always allowed. New pins require a running app; undoing an unpin made during
    /// this session is also allowed.
    public func canToggle(_ id: AppID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return pinned.contains(id) || item.isRunning || pinnedAtStart.contains(id)
    }

    /// Toggles membership, returning the new pinned state, or nil when the change is not allowed.
    public mutating func toggle(_ id: AppID) -> Bool? {
        guard canToggle(id) else { return nil }
        if pinned.contains(id) {
            pinned.remove(id)
            return false
        }
        pinned.insert(id)
        return true
    }

    public mutating func setFocus(_ id: AppID) {
        if items.contains(where: { $0.id == id }) { focus = id }
    }

    public mutating func moveFocus(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = focus.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let target = min(max(current + delta, 0), items.count - 1)
        focus = items[target].id
    }

    public mutating func appLaunched(_ id: AppID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isRunning = true
        } else {
            items.append(ManageItem(id: id, isRunning: true))
        }
    }

    public mutating func appTerminated(_ id: AppID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isRunning = false
        }
    }
}

public enum SwitcherPhase: Sendable, Equatable {
    case idle
    case switching(SwitchSession)
    case managing(ManageSession)
}

public enum SwitcherEvent: Sendable, Equatable {
    /// The registered shortcut fired. `modifiersHeld` says whether the base modifiers were still
    /// down when the press was handled; if not, the press is a complete quick switch.
    case invoke(forward: Bool, modifiersHeld: Bool, candidates: [AppID], origin: AppID?)
    /// A required base modifier is no longer held.
    case modifiersReleased
    /// Escape.
    case cancel
    /// Arrow keys while switching.
    case step(forward: Bool)
    /// The pointer actually moved over an app (not merely present when the panel appeared).
    case point(AppID)
    case click(AppID)
    case openManage(items: [ManageItem], pinned: Set<AppID>)
    case moveFocus(Int)
    case toggleFocused
    /// Done button, Return, or a click outside the editing panel.
    case done
    /// The panel lost keyboard focus to another app.
    case focusLost
    case appLaunched(AppID)
    case appTerminated(AppID)
}

public enum SwitcherEffect: Sendable, Equatable {
    /// Present the panel for the current phase, or refresh it if already visible.
    case show
    case hide
    case activate(AppID)
    case setPinned(AppID, Bool)
    /// A quick press found nothing to switch to.
    case beep
}

/// The interaction state machine. Pure and synchronous: the app layer feeds it events on the main
/// actor and performs the returned effects. Every event is ignored unless meaningful in the
/// current phase, so a late event can never commit a finished session.
public struct SwitcherMachine: Sendable {
    public private(set) var phase: SwitcherPhase = .idle
    private var nextSessionID = 1

    public init() {}

    public var sessionID: Int? {
        if case .switching(let session) = phase { return session.id }
        return nil
    }

    public mutating func handle(_ event: SwitcherEvent) -> [SwitcherEffect] {
        switch phase {
        case .idle:
            return handleIdle(event)
        case .switching(var session):
            return handleSwitching(event, &session)
        case .managing(var session):
            return handleManaging(event, &session)
        }
    }

    private mutating func handleIdle(_ event: SwitcherEvent) -> [SwitcherEffect] {
        switch event {
        case let .invoke(forward, modifiersHeld, candidates, origin):
            let session = SwitchSession(id: nextSessionID, order: candidates, origin: origin, forward: forward)
            nextSessionID += 1
            if !modifiersHeld {
                guard let target = session.selection else { return [.beep] }
                return [.activate(target)]
            }
            phase = .switching(session)
            return [.show]
        case let .openManage(items, pinned):
            phase = .managing(ManageSession(items: items, pinned: pinned))
            return [.show]
        default:
            return []
        }
    }

    private mutating func handleSwitching(_ event: SwitcherEvent, _ session: inout SwitchSession) -> [SwitcherEffect] {
        switch event {
        case let .invoke(forward, modifiersHeld, _, _):
            session.step(forward: forward)
            phase = .switching(session)
            return modifiersHeld ? [.show] : commit(session.selection)
        case .modifiersReleased:
            return commit(session.selection)
        case .cancel, .focusLost:
            phase = .idle
            return [.hide]
        case .step(let forward):
            session.step(forward: forward)
            phase = .switching(session)
            return [.show]
        case .point(let id):
            guard session.order.contains(id), session.selection != id else { return [] }
            session.select(id)
            phase = .switching(session)
            return [.show]
        case .click(let id):
            guard session.order.contains(id) else { return [] }
            return commit(id)
        case let .openManage(items, pinned):
            phase = .managing(ManageSession(items: items, pinned: pinned, focus: session.selection))
            return [.show]
        case .appTerminated(let id):
            session.remove(id)
            phase = .switching(session)
            return [.show]
        case .appLaunched, .moveFocus, .toggleFocused, .done:
            return []
        }
    }

    private mutating func handleManaging(_ event: SwitcherEvent, _ session: inout ManageSession) -> [SwitcherEffect] {
        switch event {
        case .invoke, .openManage:
            return [.show]
        case .cancel, .done, .focusLost:
            phase = .idle
            return [.hide]
        case .point(let id):
            guard session.focus != id else { return [] }
            session.setFocus(id)
            phase = .managing(session)
            return [.show]
        case .click(let id):
            session.setFocus(id)
            return toggle(id, &session)
        case .toggleFocused:
            guard let focus = session.focus else { return [] }
            return toggle(focus, &session)
        case .moveFocus(let delta):
            session.moveFocus(by: delta)
            phase = .managing(session)
            return [.show]
        case .step(let forward):
            session.moveFocus(by: forward ? 1 : -1)
            phase = .managing(session)
            return [.show]
        case .appLaunched(let id):
            session.appLaunched(id)
            phase = .managing(session)
            return [.show]
        case .appTerminated(let id):
            session.appTerminated(id)
            phase = .managing(session)
            return [.show]
        case .modifiersReleased:
            return []
        }
    }

    private mutating func commit(_ target: AppID?) -> [SwitcherEffect] {
        phase = .idle
        guard let target else { return [.hide] }
        return [.hide, .activate(target)]
    }

    private mutating func toggle(_ id: AppID, _ session: inout ManageSession) -> [SwitcherEffect] {
        guard let pinned = session.toggle(id) else {
            phase = .managing(session)
            return [.show]
        }
        phase = .managing(session)
        return [.setPinned(id, pinned), .show]
    }
}
