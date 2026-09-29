import Foundation

/// Most-recently-activated order, maintained from observed activations while PinTab runs.
///
/// Highlighting, cancelling and PinTab's own windows never touch this; the app layer only reports
/// activations of other apps that macOS actually performed.
public struct RecencyTracker: Sendable, Equatable {
    /// How long a requested-but-unconfirmed switch counts as the frontmost app.
    public static let provisionalLifetime: TimeInterval = 1.0

    public private(set) var history: [AppID] = []
    private var provisional: AppID?
    private var provisionalTime: TimeInterval = 0

    public init() {}

    /// macOS reported that `id` became the active app.
    public mutating func observedActivation(_ id: AppID) {
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
        provisional = nil
    }

    /// PinTab asked macOS to activate `id`. Until the activation is observed (or this expires), a new
    /// switching session treats `id` as the app being switched away from. This keeps a fast
    /// tap-tap toggle working when the second press arrives before macOS reports the first switch.
    public mutating func requestedActivation(_ id: AppID, at time: TimeInterval) {
        provisional = id
        provisionalTime = time
    }

    /// The app a new switching session starts from.
    public func origin(frontmost: AppID?, at time: TimeInterval) -> AppID? {
        pendingActivation(at: time) ?? frontmost
    }

    /// History with any pending activation moved to the front.
    public func order(at time: TimeInterval) -> [AppID] {
        guard let pending = pendingActivation(at: time) else { return history }
        return [pending] + history.filter { $0 != pending }
    }

    private func pendingActivation(at time: TimeInterval) -> AppID? {
        guard let provisional, time - provisionalTime <= Self.provisionalLifetime, time >= provisionalTime else {
            return nil
        }
        return provisional
    }
}

public enum SwitchOrder {
    /// Running pinned apps ordered by recent activation. Apps without recorded history follow,
    /// in the order they were pinned, so the result is deterministic.
    public static func candidates(pins: [AppID], running: Set<AppID>, recency: [AppID]) -> [AppID] {
        let live = unique(pins).filter { running.contains($0) }
        let liveSet = Set(live)
        let recent = unique(recency).filter { liveSet.contains($0) }
        let recentSet = Set(recent)
        return recent + live.filter { !recentSet.contains($0) }
    }

    /// Initial selection for a new session. From a pinned origin, move one step in the requested
    /// direction. From outside the list, forward selects the most recent pin (never skipping it)
    /// and reverse selects the last entry.
    public static func initialSelection(order: [AppID], origin: AppID?, forward: Bool) -> AppID? {
        guard !order.isEmpty else { return nil }
        if let origin, let index = order.firstIndex(of: origin) {
            return order[wrap(index + (forward ? 1 : -1), count: order.count)]
        }
        return forward ? order.first : order.last
    }

    static func wrap(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }

    static func unique(_ ids: [AppID]) -> [AppID] {
        var seen = Set<AppID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
