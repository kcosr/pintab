import ApplicationServices
import AppKit
import PinTabCore

/// Dock badges are labels, not necessarily integers (for example, "99+" or "•").
nonisolated struct AppBadge: Equatable, Sendable {
    let text: String

    init?(_ label: String?) {
        guard let label else { return nil }
        let text = String(String.UnicodeScalarView(label.unicodeScalars.filter { $0.properties.generalCategory != .control }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "0" else { return nil }
        self.text = text
    }

    /// Keep custom labels within the icon; VoiceOver still gets the full value.
    var displayText: String { text.count > 5 ? String(text.prefix(4)) + "…" : text }
}

nonisolated protocol DockBadgeReading: Sendable {
    func readBadges(for apps: [AppID: URL], dockPID: pid_t?) async -> [AppID: AppBadge]
}

/// All cross-process Accessibility calls stay on this actor, away from the main actor and key tap.
actor DockBadgeReader: DockBadgeReading {
    func readBadges(for apps: [AppID: URL], dockPID: pid_t?) -> [AppID: AppBadge] {
        guard !Task.isCancelled, !apps.isEmpty, AXIsProcessTrusted(), let dockPID else { return [:] }
        let dock = AXUIElementCreateApplication(dockPID)
        let identities = Dictionary(apps.map { (canonicalPath($0.value), $0.key) },
                                    uniquingKeysWith: { first, _ in first })
        let started = ProcessInfo.processInfo.systemUptime
        var badges: [AppID: AppBadge] = [:]
        for list in children(of: dock) {
            guard !Task.isCancelled else { return [:] }
            guard attribute(list, kAXRoleAttribute) as? String == kAXListRole else { continue }
            for item in children(of: list) {
                guard !Task.isCancelled else { return [:] }
                // A busy or unresponsive Dock must not build up an unbounded queue of work.
                guard ProcessInfo.processInfo.systemUptime - started < 0.75 else { return badges }
                guard attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
                      let url = attribute(item, kAXURLAttribute) as? URL,
                      let id = identities[canonicalPath(url)] else { continue }
                // AXStatusLabel is supplied by the Dock. Missing/unsupported values mean no badge.
                if let badge = AppBadge(attribute(item, "AXStatusLabel") as? String) {
                    badges[id] = badge
                }
            }
        }
        return AXIsProcessTrusted() ? badges : [:]
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Polls only while the switching panel is open. A fresh snapshot clears badges removed by an app.
final class DockBadgeMonitor {
    var onChange: () -> Void = {}
    private(set) var badges: [AppID: AppBadge] = [:]
    private let reader: any DockBadgeReading
    private let isTrusted: () -> Bool
    private let dockPID: () -> pid_t?
    private var apps: [AppID: URL] = [:]
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(reader: any DockBadgeReading = DockBadgeReader(),
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         dockPID: @escaping () -> pid_t? = {
             NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
         }) {
        self.reader = reader
        self.isTrusted = isTrusted
        self.dockPID = dockPID
    }

    func start(apps: [AppID: URL]) {
        guard !apps.isEmpty else { stop(); return }
        guard self.apps != apps || timer == nil else { return }
        stop()
        self.apps = apps
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        apps = [:]
        replaceBadges([:])
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !apps.isEmpty else { return nil }
        guard isTrusted() else { replaceBadges([:]); return nil }
        if let task { return task }
        let generation = generation
        let apps = apps
        let pid = dockPID()
        task = Task { [weak self, reader] in
            let snapshot = await reader.readBadges(for: apps, dockPID: pid)
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.task = nil
            self.replaceBadges(self.isTrusted() ? snapshot : [:])
        }
        return task
    }

    private func replaceBadges(_ badges: [AppID: AppBadge]) {
        guard self.badges != badges else { return }
        self.badges = badges
        onChange()
    }
}
