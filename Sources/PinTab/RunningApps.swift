import AppKit
import PinTabCore

/// Catalog of eligible running apps (regular activation policy, excluding PinTab), plus
/// most-recently-activated order observed from NSWorkspace.
final class RunningApps: NSObject {
    var onLaunch: ((AppID) -> Void)?
    var onTerminate: ((AppID) -> Void)?

    private(set) var recency = RecencyTracker()
    private var lastActivePID: [AppID: pid_t] = [:]
    private var iconCache: [AppID: NSImage] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didActivate(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(didLaunch(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(didTerminate(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // History before PinTab started is not available; start with the current frontmost app.
        if let front = NSWorkspace.shared.frontmostApplication, let id = identity(of: front) {
            record(activation: front, id: id)
        }
    }

    // MARK: Catalog

    func identity(of app: NSRunningApplication) -> AppID? {
        guard !app.isTerminated,
              app.activationPolicy == .regular,
              app.processIdentifier != ownPID,
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty
        else { return nil }
        return AppID(bundleID)
    }

    var eligible: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { identity(of: $0) != nil }
    }

    var runningIDs: Set<AppID> {
        Set(eligible.compactMap { identity(of: $0) })
    }

    /// Running apps sorted by display name, for the management layout.
    var runningByName: [AppID] {
        var names: [AppID: String] = [:]
        for app in eligible {
            if let id = identity(of: app), names[id] == nil { names[id] = app.localizedName ?? id.bundleID }
        }
        return names.keys.sorted {
            let order = names[$0]!.localizedStandardCompare(names[$1]!)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }

    var frontmostID: AppID? {
        NSWorkspace.shared.frontmostApplication.flatMap { identity(of: $0) }
    }

    /// The live process to activate for an identity: the most recently activated instance, else
    /// the most recently launched one. Resolved fresh every time; never cached across sessions.
    func instance(for id: AppID) -> NSRunningApplication? {
        let matches = eligible.filter { $0.bundleIdentifier == id.bundleID }
        if let pid = lastActivePID[id], let match = matches.first(where: { $0.processIdentifier == pid }) {
            return match
        }
        return matches.max { lhs, rhs in
            let l = lhs.launchDate ?? .distantPast, r = rhs.launchDate ?? .distantPast
            return l == r ? lhs.processIdentifier < rhs.processIdentifier : l < r
        }
    }

    func name(for id: AppID, fallback: String? = nil) -> String {
        if let name = instance(for: id)?.localizedName, !name.isEmpty { return name }
        if let fallback, !fallback.isEmpty { return fallback }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id.bundleID
    }

    func icon(for id: AppID) -> NSImage {
        if let icon = instance(for: id)?.icon { return icon }
        if let cached = iconCache[id] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        iconCache[id] = icon
        return icon
    }

    // MARK: Recency

    func requestedActivation(_ id: AppID) {
        recency.requestedActivation(id, at: uptime())
    }

    private func record(activation app: NSRunningApplication, id: AppID) {
        recency.observedActivation(id)
        lastActivePID[id] = app.processIdentifier
    }

    // MARK: Notifications (posted on the main thread)

    private func app(from note: Notification) -> NSRunningApplication? {
        note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    @objc private func didActivate(_ note: Notification) {
        guard let app = app(from: note), let id = identity(of: app) else { return }
        record(activation: app, id: id)
        Log.activation.debug("Observed activation of \(id.bundleID, privacy: .public)")
        // Some apps only become regular after launching; make sure an open editor knows about them.
        onLaunch?(id)
    }

    @objc private func didLaunch(_ note: Notification) {
        guard let app = app(from: note), let id = identity(of: app) else { return }
        onLaunch?(id)
    }

    @objc private func didTerminate(_ note: Notification) {
        guard let app = app(from: note), app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier else { return }
        let id = AppID(bundleID)
        if lastActivePID[id] == app.processIdentifier { lastActivePID[id] = nil }
        // Another instance of the same app may still be running.
        if instance(for: id) == nil { onTerminate?(id) }
    }
}
