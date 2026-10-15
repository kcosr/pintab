import AppKit
import PinTabCore
import Testing
@testable import PinTab

@Suite("Dock badge labels")
struct DockBadgeLabelTests {
    @Test(arguments: [nil, "", "  \n", "0"] as [String?])
    func absentAndZeroLabelsAreHidden(_ label: String?) {
        #expect(AppBadge(label) == nil)
    }

    @Test(arguments: ["12", "99+", "•", "!", "١٢"])
    func preservesLabelsInsteadOfGuessingCounts(_ label: String) {
        #expect(AppBadge(label)?.text == label)
        #expect(AppBadge(label)?.displayText == label)
    }

    @Test func removesControlCharactersAndBoundsCustomLabels() {
        let badge = AppBadge(" \n12\t3456789\n ")
        #expect(badge?.text == "123456789")
        #expect(badge?.displayText == "1234…")
        let emoji = "👩‍💻"
        #expect(AppBadge(String(repeating: emoji, count: 6))?.displayText == String(repeating: emoji, count: 4) + "…")
    }
}

private actor BadgeReaderStub: DockBadgeReading {
    private var requests: [CheckedContinuation<[AppID: AppBadge], Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var requestCount: Int { requests.count }

    func readBadges(for apps: [AppID: URL], dockPID: pid_t?) async -> [AppID: AppBadge] {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with badges: [AppID: AppBadge]) {
        requests[index].resume(returning: badges)
    }
}

@Suite("Dock badge refresh lifecycle", .timeLimit(.minutes(1)))
struct DockBadgeMonitorTests {
    let app = AppID("com.test.alpha")
    var targets: [AppID: URL] { [app: URL(fileURLWithPath: "/Applications/Alpha.app")] }

    @Test func doesNotReadWithoutPermission() async {
        let reader = BadgeReaderStub()
        let monitor = DockBadgeMonitor(reader: reader, isTrusted: { false }, dockPID: { 1 })
        defer { monitor.stop() }
        monitor.start(apps: targets)
        monitor.refresh()
        #expect(await reader.requestCount == 0)
        #expect(monitor.badges.isEmpty)
    }

    @Test func freshEmptySnapshotClearsAnOldBadge() async {
        let reader = BadgeReaderStub()
        let monitor = DockBadgeMonitor(reader: reader, isTrusted: { true }, dockPID: { 1 })
        defer { monitor.stop() }
        monitor.start(apps: targets)
        let first = monitor.refresh()
        await reader.waitForRequests(1)
        await reader.complete(0, with: [app: AppBadge("12")!])
        await first?.value
        #expect(monitor.badges[app]?.text == "12")
        let second = monitor.refresh()
        await reader.waitForRequests(2)
        await reader.complete(1, with: [:])
        await second?.value
        #expect(monitor.badges.isEmpty)
    }

    @Test func restartingDiscardsThePreviousSessionsInFlightRead() async {
        let reader = BadgeReaderStub()
        let monitor = DockBadgeMonitor(reader: reader, isTrusted: { true }, dockPID: { 1 })
        defer { monitor.stop() }
        var received: [String] = []
        monitor.onChange = { [weak monitor] in
            if let text = monitor?.badges[app]?.text { received.append(text) }
        }
        monitor.start(apps: targets)
        let old = monitor.refresh()
        await reader.waitForRequests(1)
        monitor.stop()
        monitor.start(apps: targets)
        let current = monitor.refresh()
        await reader.waitForRequests(2)
        await reader.complete(0, with: [app: AppBadge("old")!])
        await reader.complete(1, with: [app: AppBadge("new")!])
        await old?.value
        await current?.value
        #expect(monitor.badges[app]?.text == "new")
        #expect(received == ["new"])
        monitor.stop()
        #expect(monitor.badges.isEmpty)
    }

    @Test func repeatedStartsAndRefreshesDoNotOverlapReads() async {
        let reader = BadgeReaderStub()
        let monitor = DockBadgeMonitor(reader: reader, isTrusted: { true }, dockPID: { 1 })
        defer { monitor.stop() }
        monitor.start(apps: targets)
        let pending = monitor.refresh()
        for _ in 0..<10 {
            monitor.start(apps: targets)
            monitor.refresh()
        }
        await reader.waitForRequests(1)
        #expect(await reader.requestCount == 1)
        await reader.complete(0, with: [app: AppBadge("3")!])
        await pending?.value
        #expect(monitor.badges[app]?.text == "3")
    }

    @Test func permissionRevokedDuringAReadDiscardsItsResultAndCanRecover() async {
        let reader = BadgeReaderStub()
        var trusted = true
        let monitor = DockBadgeMonitor(reader: reader, isTrusted: { trusted }, dockPID: { 1 })
        defer { monitor.stop() }
        monitor.start(apps: targets)
        let pending = monitor.refresh()
        await reader.waitForRequests(1)
        trusted = false
        await reader.complete(0, with: [app: AppBadge("12")!])
        await pending?.value
        #expect(monitor.badges.isEmpty)
        trusted = true
        let recovery = monitor.refresh()
        await reader.waitForRequests(2)
        await reader.complete(1, with: [app: AppBadge("2")!])
        await recovery?.value
        #expect(monitor.badges[app]?.text == "2")
        trusted = false
        monitor.refresh()
        #expect(monitor.badges.isEmpty)
    }
}

@Suite("App badge preference")
struct AppBadgePreferenceTests {
    @Test func isOptionalAndPersistsWithoutEnablingCommandTab() {
        let name = "dev.local.PinTab.badge-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        #expect(!preferences.showAppBadges)
        preferences.setShowAppBadges(true)
        let restored = Preferences(defaults: defaults)
        #expect(restored.showAppBadges)
        #expect(!restored.useCommandTab)
        restored.setShowAppBadges(false)
        #expect(!Preferences(defaults: defaults).showAppBadges)
    }
}
