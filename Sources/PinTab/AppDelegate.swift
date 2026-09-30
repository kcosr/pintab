import AppKit
import PinTabCore
import ServiceManagement
import SwiftUI

/// Owns the app's lifetime: status menu, settings window, shortcut registration and the switcher.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private let state = AppState()
    private let apps = RunningApps()
    private lazy var activator = Activator(apps: apps)
    private lazy var switcher = SwitcherController(preferences: preferences, apps: apps, activator: activator)
    private let eventTap = EventTap()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
            Log.app.notice("Another PinTab is already running; quitting")
            NSApp.terminate(nil)
            return
        }
        Log.app.notice("PinTab started (\(Bundle.main.bundleIdentifier ?? "unbundled", privacy: .public))")

        NSApp.mainMenu = makeMainMenu()
        setUpStatusItem()

        apps.onLaunch = { [weak self] id in self?.switcher.appLaunched(id) }
        apps.onTerminate = { [weak self] id in self?.switcher.appTerminated(id) }

        HotKeys.shared.onPress = { [weak self] forward in
            guard let shortcut = HotKeys.shared.registered else { return }
            self?.switcher.cyclePressed(forward: forward, shortcut: shortcut, source: .hotKey)
        }
        activator.shouldIntervene = { [weak self] in self?.switcher.isActive == false }
        switcher.onPause = { [weak self] in self?.setPaused(true) }
        switcher.canHandOff = { [weak self] in self?.eventTap.isInstalled == true }
        switcher.beginHandOff = { [weak self] in self?.eventTap.beginHandOff() ?? false }
        switcher.replayHandOff = { [weak self] in self?.eventTap.replayCommandTab() }
        HotKeys.shared.installHandler()
        applyShortcut()

        eventTap.phase = { [weak self] in self?.tapPhase ?? .suspended }
        eventTap.onAction = { [weak self] action in self?.switcher.handleTapAction(action) }
        eventTap.onStateChange = { [weak self] in self?.refreshCommandTabState() }
        applyCommandTab()

        if let preview = UserDefaults.standard.string(forKey: "PinTabPreview") {
            // Development aid; the argument domain is not persisted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    if preview == "settings" { self?.showSettings() } else { self?.switcher.showPreview(preview) }
                }
            }
        } else if preferences.shortcut == nil && !preferences.useCommandTab {
            showSettings()
        } else if preferences.useCommandTab && !EventTap.isTrusted {
            // A new build needs Accessibility permission again (ad-hoc signing changes its identity).
            // Prompting also re-adds PinTab to the Accessibility list after `make install` reset it.
            EventTap.requestTrust()
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.closeAll()
        eventTap.disable(immediately: true)
        HotKeys.shared.unregister()
    }

    // MARK: ⌘Tab mode

    /// The event tap passes everything through while paused or recording, or when the mode is off.
    private var tapPhase: TapPhase {
        guard preferences.useCommandTab, !state.isPaused, !state.isRecordingShortcut else { return .suspended }
        if switcher.isPreviewing { return .idle }
        return switcher.tapPhase
    }

    private func applyCommandTab() {
        if preferences.useCommandTab && !state.isPaused {
            eventTap.enable()
        } else {
            eventTap.disable()
        }
        refreshCommandTabState()
    }

    private func refreshCommandTabState() {
        if !preferences.useCommandTab {
            state.commandTabStatus = .off
        } else if state.isPaused {
            // Pausing removes the tap on purpose; only missing permission is worth a warning.
            state.commandTabStatus = EventTap.isTrusted ? .active : .needsPermission
        } else {
            state.commandTabStatus = eventTap.isInstalled ? .active : .needsPermission
        }
        updateStatusIcon()
    }

    private func setUseCommandTab(_ enabled: Bool) {
        preferences.setUseCommandTab(enabled)
        Log.app.notice("⌘Tab mode \(enabled ? "on" : "off", privacy: .public)")
        if enabled && !EventTap.isTrusted { EventTap.requestTrust() }
        applyCommandTab()
    }

    // MARK: Shortcut

    /// Registers the saved shortcut unless paused or recording. Anything else leaves it unregistered.
    private func applyShortcut() {
        HotKeys.shared.unregister()
        defer { updateStatusIcon() }
        guard !state.isPaused, !state.isRecordingShortcut, let shortcut = preferences.shortcut else { return }
        do {
            try HotKeys.shared.register(shortcut)
            state.registrationError = nil
        } catch {
            state.registrationError = "\(KeyNames.display(shortcut)) is unavailable. \(error.message)"
            Log.input.error("Registration failed: \(error.message, privacy: .public)")
        }
    }

    /// Validates and registers a newly recorded shortcut. On failure the previous one stays in effect.
    private func changeShortcut(_ shortcut: Shortcut) -> String? {
        if let problem = shortcut.validate() { return problem.message }
        do {
            try HotKeys.shared.register(shortcut)
        } catch {
            return "\(KeyNames.display(shortcut)) is unavailable. \(error.message)"
        }
        preferences.setShortcut(shortcut)
        state.registrationError = nil
        Log.app.notice("Shortcut changed to \(KeyNames.display(shortcut), privacy: .public)")
        return nil
    }

    private func beginRecording() {
        state.isRecordingShortcut = true
        switcher.cancelSwitching()
        applyShortcut()
    }

    private func endRecording() {
        state.isRecordingShortcut = false
        applyShortcut()
    }

    private func setPaused(_ paused: Bool) {
        state.isPaused = paused
        if paused { switcher.cancelSwitching() }
        applyShortcut()
        applyCommandTab()
        Log.app.notice("\(paused ? "Paused" : "Resumed", privacy: .public)")
    }

    // MARK: Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            state.loginItemError = nil
        } catch {
            state.loginItemError = "Could not change the login item: \(error.localizedDescription)"
        }
        state.loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: Status menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("PinTab")
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let hotKeyActive = preferences.shortcut != nil && state.registrationError == nil
        let inactive = state.isPaused || !(hotKeyActive || state.commandTabStatus == .active)
        statusItem?.button?.image = StatusIcon.image
        // Paused, or no working shortcut: the standard dimmed look for an inactive status item.
        statusItem?.button?.appearsDisabled = inactive
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Menu actions change pins and pause state; don't let an open editor show stale state.
        switcher.closeAll()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if state.commandTabStatus == .needsPermission && !state.isPaused {
            menu.addItem(item("Allow ⌘Tab in Accessibility Settings…", #selector(openAccessibilitySettings)))
        }
        menu.addItem(.separator())

        if let front = NSWorkspace.shared.frontmostApplication, let id = apps.identity(of: front) {
            let name = front.localizedName ?? id.bundleID
            let pinned = preferences.pins.contains(id)
            let item = NSMenuItem(title: pinned ? "Unpin “\(name)”" : "Pin “\(name)”",
                                  action: #selector(toggleFrontmostPin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.bundleID
            menu.addItem(item)
        }
        menu.addItem(item("Manage Pinned Apps…", #selector(managePins)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item(state.isPaused ? "Resume PinTab" : "Pause PinTab", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(item("Quit PinTab", #selector(quit), key: "q"))
    }

    private var statusText: String {
        if state.isPaused { return "PinTab is paused" }
        var working: [String] = []
        if state.commandTabStatus == .active { working.append("⌘Tab") }
        if let shortcut = preferences.shortcut, state.registrationError == nil {
            working.append(KeyNames.display(shortcut))
        }
        if !working.isEmpty {
            let failed = preferences.shortcut.flatMap { state.registrationError != nil ? KeyNames.display($0) : nil }
            return "Switch with " + working.joined(separator: " or ") + (failed.map { " (\($0) unavailable)" } ?? "")
        }
        if state.commandTabStatus == .needsPermission { return "⌘Tab needs Accessibility permission" }
        if let shortcut = preferences.shortcut { return "\(KeyNames.display(shortcut)) is unavailable" }
        return "No shortcut set"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleFrontmostPin(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        let id = AppID(bundleID)
        preferences.setPinned(id, name: apps.name(for: id), pinned: !preferences.pins.contains(id))
    }

    @objc private func managePins() {
        // Let the menu finish closing before the panel takes keyboard focus.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.switcher.openManage() }
        }
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openAccessibilitySettings() {
        askForAccessibility()
    }

    /// Prompting adds PinTab to the Accessibility list (it may have been reset); then show the pane.
    private func askForAccessibility() {
        if !EventTap.isTrusted { EventTap.requestTrust() }
        EventTap.openAccessibilitySettings()
    }

    @objc private func togglePause() {
        setPaused(!state.isPaused)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Settings window

    private func showSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                beginRecording: { [weak self] in self?.beginRecording() },
                endRecording: { [weak self] in self?.endRecording() },
                changeShortcut: { [weak self] in self?.changeShortcut($0) },
                setPaused: { [weak self] in self?.setPaused($0) },
                setUseCommandTab: { [weak self] in self?.setUseCommandTab($0) },
                openAccessibilitySettings: { [weak self] in self?.askForAccessibility() },
                setLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin($0) },
                managePins: { [weak self] in self?.switcher.openManage() }
            )
            let view = SettingsView(preferences: preferences, state: state, actions: actions)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "PinTab Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        state.loginItemStatus = SMAppService.mainApp.status
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        // Ends an in-progress recording through the recorder itself (resignFirstResponder → stop).
        window.makeFirstResponder(nil)
        if state.isRecordingShortcut { endRecording() }
        state.recorderMessage = nil
        // Hand focus back to whatever was in front before Settings.
        NSApp.hide(nil)
    }

    // MARK: Main menu (key equivalents only; accessory apps show no menu bar)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "PinTab")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit PinTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}
