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
            self?.switcher.cyclePressed(forward: forward, fromHotKey: true)
        }
        activator.shouldIntervene = { [weak self] in self?.switcher.isActive == false }
        HotKeys.shared.installHandler()
        applyShortcut()

        if let preview = UserDefaults.standard.string(forKey: "PinTabPreview") {
            // Development aid; the argument domain is not persisted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.switcher.showPreview(preview) }
            }
        } else if preferences.shortcut == nil {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.closeAll()
        HotKeys.shared.unregister()
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
        let inactive = state.isPaused || preferences.shortcut == nil || state.registrationError != nil
        let image = NSImage(systemSymbolName: inactive ? "pin.slash" : "pin.fill", accessibilityDescription: "PinTab")
        image?.isTemplate = true
        statusItem?.button?.image = image
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
        guard let shortcut = preferences.shortcut else { return "No shortcut set" }
        if state.registrationError != nil { return "\(KeyNames.display(shortcut)) is unavailable" }
        return "Switch with \(KeyNames.display(shortcut))"
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
