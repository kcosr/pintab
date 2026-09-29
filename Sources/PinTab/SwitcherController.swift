import AppKit
import PinTabCore

/// Feeds input into the pure SwitcherMachine and performs its effects: presenting the panel,
/// activating apps and saving pin changes. All work happens on the main actor.
final class SwitcherController: NSObject {
    private var machine = SwitcherMachine()
    private let preferences: Preferences
    private let apps: RunningApps
    private let activator: Activator
    private let model = SwitcherViewModel()
    private lazy var panel = SwitcherPanel(model: model)

    private var isPresented = false
    private var screen: NSScreen?
    private var pointerStart: NSPoint = .zero
    private var pointerMoved = false
    private var localMonitor: Any?
    private var globalMouseMonitor: Any?
    private var pollTimer: Timer?
    private var revealToken = 0
    private var announcedSelection: AppID?
    private var isPreview = false

    /// Delay before the switching panel becomes visible, so quick taps switch without a flash.
    private let revealDelay: TimeInterval = 0.12

    init(preferences: Preferences, apps: RunningApps, activator: Activator) {
        self.preferences = preferences
        self.apps = apps
        self.activator = activator
        super.init()
        // Panel callbacks are ignored once the panel is dismissed, so a click queued behind a
        // modifier release cannot reopen anything after the switch committed.
        model.onPoint = { [weak self] id in self?.pointed(at: id) }
        model.onClick = { [weak self] id in
            guard let self, self.isPresented else { return }
            self.send(.click(id))
        }
        model.onManage = { [weak self] in
            guard let self, self.isPresented else { return }
            self.openManage()
        }
        model.onDone = { [weak self] in
            guard let self, self.isPresented else { return }
            self.send(.done)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    var isActive: Bool {
        if case .idle = machine.phase { return false }
        return true
    }

    // MARK: Entry points

    /// A press of the registered shortcut (or of its key while the panel has focus).
    func cyclePressed(forward: Bool, fromHotKey: Bool) {
        guard let shortcut = preferences.shortcut else { return }
        let held = shortcut.baseModifiersHeld(in: Self.currentModifiers())
        Log.input.notice("Press \(forward ? "forward" : "reverse", privacy: .public) held=\(held) source=\(fromHotKey ? "hotkey" : "panel", privacy: .public)")

        guard case .idle = machine.phase else {
            send(.invoke(forward: forward, modifiersHeld: held, candidates: [], origin: nil))
            return
        }
        if preferences.pins.pins.isEmpty {
            // Nothing to switch between yet: go straight to editing rather than switching among everything.
            openManage()
            return
        }
        let now = uptime()
        let candidates = SwitchOrder.candidates(pins: preferences.pins.ids, running: apps.runningIDs,
                                                recency: apps.recency.order(at: now))
        let origin = apps.recency.origin(frontmost: apps.frontmostID, at: now)
        send(.invoke(forward: forward, modifiersHeld: held, candidates: candidates, origin: origin))
    }

    func openManage() {
        let items = ManageSession.layout(pins: preferences.pins.ids, runningByName: apps.runningByName,
                                         recency: apps.recency.order(at: uptime()))
        send(.openManage(items: items, pinned: Set(preferences.pins.ids)))
    }

    func appLaunched(_ id: AppID) {
        preferences.updateName(id, to: apps.name(for: id))
        send(.appLaunched(id))
    }

    func appTerminated(_ id: AppID) {
        send(.appTerminated(id))
    }

    /// Ends a switching session (for example when the shortcut is paused or changed).
    /// An open editing panel is left alone.
    func cancelSwitching() {
        if machine.sessionID != nil { send(.cancel) }
    }

    func closeAll() {
        if isActive { send(.cancel) }
    }

    /// Development aid (`open PinTab.app --args -PinTabPreview switching|managing`): shows a panel
    /// for a few seconds without keyboard input so its layout can be inspected. Nothing is activated.
    func showPreview(_ mode: String, seconds: TimeInterval = 6) {
        isPreview = true
        if mode == "managing" {
            openManage()
        } else {
            let candidates = SwitchOrder.candidates(pins: preferences.pins.ids, running: apps.runningIDs,
                                                    recency: apps.recency.order(at: uptime()))
            send(.invoke(forward: true, modifiersHeld: true, candidates: candidates, origin: apps.frontmostID))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.closeAll()
                self?.isPreview = false
            }
        }
    }

    // MARK: State machine

    private func send(_ event: SwitcherEvent) {
        let effects = machine.handle(event)
        if !effects.isEmpty {
            Log.session.debug("\(String(describing: event), privacy: .public) → \(String(describing: effects), privacy: .public)")
        }
        for effect in effects {
            switch effect {
            case .show:
                present()
            case .hide:
                dismiss()
            case .activate(let id):
                Log.session.notice("Commit \(id.bundleID, privacy: .public)")
                activator.activate(id)
            case let .setPinned(id, pinned):
                preferences.setPinned(id, name: apps.name(for: id, fallback: preferences.pins.name(of: id)), pinned: pinned)
            case .beep:
                NSSound.beep()
            }
        }
        // Invariant: an idle machine never leaves the panel, monitors or timers behind.
        if !isActive, isPresented { dismiss() }
    }

    // MARK: Presentation

    private func present() {
        let isSwitching = machine.sessionID != nil
        if !isPresented {
            isPresented = true
            screen = Self.screenUnderPointer()
            pointerStart = NSEvent.mouseLocation
            pointerMoved = false
            announcedSelection = nil
            render()
            layout()
            installMonitors()
            // Closing Settings hides PinTab to return focus; a hidden app's windows cannot appear.
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            panel.alphaValue = isSwitching ? 0 : 1
            panel.ignoresMouseEvents = isSwitching
            panel.orderFrontRegardless()
            panel.makeKey()
            Log.session.notice("Panel shown (\(isSwitching ? "switching" : "managing", privacy: .public)), key=\(self.panel.isKeyWindow)")
            if isSwitching {
                startPolling()
                scheduleReveal()
                // Catch a release that happened before the panel could receive key events.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.checkModifiers(source: "initial check") }
                }
            }
        } else {
            render()
            layout()
            if !isSwitching {
                // Switching became editing: editing is independent of the keyboard and always visible.
                stopPolling()
                reveal()
            }
        }
        announceSelection()
    }

    private func dismiss() {
        guard isPresented else { return }
        isPresented = false
        revealToken += 1
        stopPolling()
        removeMonitors()
        panel.orderOut(nil)
        Log.session.notice("Panel hidden")
    }

    private func scheduleReveal() {
        revealToken += 1
        let token = revealToken
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.revealToken, self.isPresented else { return }
                self.reveal()
            }
        }
    }

    private func reveal() {
        revealToken += 1
        panel.ignoresMouseEvents = false
        guard panel.alphaValue < 1 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 1
            }
        }
    }

    private func render() {
        switch machine.phase {
        case .idle:
            return
        case .switching(let session):
            model.mode = .switching
            model.tiles = session.order.map { tile(for: $0, pinned: true, running: true, canToggle: false) }
            model.selection = session.selection
            model.message = session.order.isEmpty ? "No pinned apps are running" : nil
        case .managing(let session):
            model.mode = .managing
            model.tiles = session.items.map {
                tile(for: $0.id, pinned: session.pinned.contains($0.id), running: $0.isRunning,
                     canToggle: session.canToggle($0.id))
            }
            model.selection = session.focus
            model.message = session.pinned.isEmpty
                ? "Nothing is pinned yet. Click running apps to add them to the switcher."
                : nil
        }
        computeMetrics()
    }

    private func tile(for id: AppID, pinned: Bool, running: Bool, canToggle: Bool) -> SwitcherViewModel.Tile {
        SwitcherViewModel.Tile(id: id, name: apps.name(for: id, fallback: preferences.pins.name(of: id)),
                               icon: apps.icon(for: id), isPinned: pinned, isRunning: running, canToggle: canToggle)
    }

    private func computeMetrics() {
        guard let visible = (screen ?? Self.screenUnderPointer())?.visibleFrame else { return }
        let maxContent = visible.width * 0.9 - Metrics.panelPadding * 2
        let count = CGFloat(model.tiles.count)
        switch model.mode {
        case .switching:
            let natural = count * Metrics.tileSize + max(count - 1, 0) * Metrics.tileSpacing
            model.rowWidth = min(natural, maxContent)
            model.contentWidth = max(model.rowWidth, Metrics.minSwitchWidth)
        case .managing:
            let step = Metrics.manageTileWidth + Metrics.manageSpacing
            let fit = max(1, Int((maxContent + Metrics.manageSpacing) / step))
            let columns = max(1, min(model.tiles.count, fit, Metrics.maxManageColumns))
            model.columns = columns
            model.rowWidth = CGFloat(columns) * step - Metrics.manageSpacing
            model.contentWidth = min(max(model.rowWidth, Metrics.minManageWidth), maxContent)
            let rows = CGFloat((max(model.tiles.count, 1) + columns - 1) / columns)
            let natural = rows * (Metrics.manageTileHeight + Metrics.manageSpacing) - Metrics.manageSpacing
            model.gridHeight = min(natural, visible.height * 0.6)
        }
    }

    private func layout() {
        guard let screen = screen ?? NSScreen.main else { return }
        hostingLayoutPass()
        let size = panel.hostingView.fittingSize
        let visible = screen.visibleFrame
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.midY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func hostingLayoutPass() {
        panel.hostingView.needsLayout = true
        panel.hostingView.layoutSubtreeIfNeeded()
    }

    private func announceSelection() {
        guard let selection = model.selection, selection != announcedSelection,
              let name = model.tiles.first(where: { $0.id == selection })?.name
        else { return }
        announcedSelection = selection
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: name, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Input

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event) ? nil : event
        }
        // A click in another app ends the session (and closes editing).
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                Log.session.notice("Click outside the panel")
                self.send(.focusLost)
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMonitor = nil
        globalMouseMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handleLocal(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            if machine.sessionID != nil, !isPreview, let shortcut = preferences.shortcut,
               !shortcut.baseModifiersHeld(in: modifiers) {
                Log.input.notice("Modifier release seen by panel")
                send(.modifiersReleased)
            }
            return false
        case .keyDown:
            guard event.window === panel else { return false }
            if machine.sessionID != nil {
                handleSwitchingKey(event, modifiers)
            } else {
                handleManagingKey(event, modifiers)
            }
            return true
        default:
            return false
        }
    }

    private func handleSwitchingKey(_ event: NSEvent, _ modifiers: KeyModifiers) {
        if let shortcut = preferences.shortcut, event.keyCode == shortcut.keyCode {
            // Exact forward/reverse combinations arrive through the registered hotkey. The panel only
            // counts what the hotkey cannot deliver: key repeat and presses with other modifier sets.
            let registered = modifiers == shortcut.modifiers || modifiers == shortcut.reverseModifiers
            if event.isARepeat || !registered {
                cyclePressed(forward: !modifiers.contains(.shift), fromHotKey: false)
            }
            return
        }
        switch event.keyCode {
        case KeyCode.escape, KeyCode.period:
            send(.cancel)
        case KeyCode.leftArrow, KeyCode.upArrow:
            send(.step(forward: false))
        case KeyCode.rightArrow, KeyCode.downArrow:
            send(.step(forward: true))
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if let selection = model.selection { send(.click(selection)) }
        case KeyCode.m:
            openManage()
        default:
            break // Other keys are ignored while switching; nothing is replayed to other apps.
        }
    }

    private func handleManagingKey(_ event: NSEvent, _ modifiers: KeyModifiers) {
        switch event.keyCode {
        case KeyCode.escape:
            send(.cancel)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            send(.done)
        case KeyCode.space:
            send(.toggleFocused)
        case KeyCode.leftArrow:
            send(.moveFocus(-1))
        case KeyCode.rightArrow:
            send(.moveFocus(1))
        case KeyCode.upArrow:
            send(.moveFocus(-model.columns))
        case KeyCode.downArrow:
            send(.moveFocus(model.columns))
        case KeyCode.tab:
            send(.moveFocus(modifiers.contains(.shift) ? -1 : 1))
        default:
            break
        }
    }

    /// Hover only selects after the pointer has actually moved since the panel appeared.
    private func pointed(at id: AppID) {
        if !pointerMoved {
            let location = NSEvent.mouseLocation
            guard hypot(location.x - pointerStart.x, location.y - pointerStart.y) > 3 else { return }
            pointerMoved = true
        }
        send(.point(id))
    }

    // Safety net for modifier release: polls only while a switching session is open.
    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkModifiers(source: "poll") }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkModifiers(source: StaticString) {
        guard machine.sessionID != nil, !isPreview, let shortcut = preferences.shortcut else { return }
        if !shortcut.baseModifiersHeld(in: Self.currentModifiers()) {
            Log.input.notice("Modifier release seen by \(source)")
            send(.modifiersReleased)
        }
    }

    static func currentModifiers() -> KeyModifiers {
        KeyModifiers(eventFlags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    }

    // MARK: Window events

    @objc private func panelDidResignKey(_ note: Notification) {
        guard isPresented else { return }
        Log.session.notice("Panel lost keyboard focus")
        send(.focusLost)
    }

    @objc private func screensChanged(_ note: Notification) {
        guard isPresented else { return }
        if let screen, !NSScreen.screens.contains(screen) { self.screen = Self.screenUnderPointer() }
        render()
        layout()
    }

    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
