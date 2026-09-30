import ApplicationServices
import AppKit
import PinTabCore

/// Owns the CGEventTap behind "Use ⌘Tab" mode. Requires Accessibility permission.
///
/// macOS never delivers ⌘Tab to Carbon hotkeys, but an active session tap sees it before the system
/// switcher does. The tap's source is on the main run loop, so every keystroke system-wide waits for
/// the callback: `phase` and `onAction` must stay cheap. The tap holds an unretained pointer to this
/// object, so keep it alive while enabled.
final class EventTap {
    /// Queried synchronously inside the tap callback (main thread) for every event.
    var phase: () -> TapPhase = { .suspended }
    /// Receives actions on the main thread; must return quickly.
    var onAction: (TapAction) -> Void = { _ in }
    /// Called whenever `isInstalled` or trust changes, so UI can refresh.
    var onStateChange: () -> Void = {}

    private(set) var isInstalled = false

    /// Tags keystrokes PinTab posts itself, so its own tap always lets them through.
    nonisolated fileprivate static let syntheticMarker: Int64 = 0x5054_4142 // 'PTAB'

    private var enabled = false
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var pollTimer: Timer?
    private var lastTrusted: Bool?
    private var createFailureLogged = false
    private var filter = CommandTabFilter()
    /// Disabled while PinTab still owns swallowed keys: the tap stays until they are released.
    private var draining = false
    private var drainTimer: Timer?
    private var drainStarted: TimeInterval = 0
    /// Watches for the ⌘ release during a hand-off, in case the tap never sees it.
    private var handOffWatch: Timer?
    /// Progress of the replayed ⌘Tab through the tap, so a replay overtaken by the ⌘ release is dropped.
    private enum Replay { case none, posted, downAdmitted }
    private var replay = Replay.none

    /// Whether PinTab is currently trusted for Accessibility (AXIsProcessTrusted()).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS Accessibility prompt if not trusted (AXIsProcessTrustedWithOptions with the prompt option).
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt; the C global itself is not concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Installs the tap if trusted. If not trusted, polls trust about once per second and installs as soon as
    /// it is granted, until disable() is called. Idempotent.
    func enable() {
        if draining {
            // Re-enabled before swallowed keys were released: keep the tap, and keep watching an
            // active hand-off (disable() stopped the watch).
            stopDraining()
            if filter.isHandingOff { startHandOffWatch() }
        }
        guard !enabled else { return }
        enabled = true
        let trusted = Self.isTrusted
        lastTrusted = trusted
        if !isInstalled && !(trusted && install()) {
            Log.input.notice("Waiting for Accessibility permission to install the ⌘Tab event tap")
        }
        startPolling()
        onStateChange()
    }

    /// Removes the tap (if any) and stops polling. Idempotent. While PinTab still owns swallowed keys
    /// (for example the P that paused it), the tap stays until they are released so their key-ups and
    /// repeats never reach other apps; `phase` is `.suspended` meanwhile, so everything else passes.
    /// Pass `immediately` when quitting.
    func disable(immediately: Bool = false) {
        enabled = false
        stopPolling()
        stopHandOffWatch()
        lastTrusted = nil
        createFailureLogged = false
        guard isInstalled else {
            filter.reset()
            return
        }
        if filter.ownsKeys && !immediately {
            startDraining()
            return
        }
        uninstall()
        onStateChange()
    }

    // MARK: - Hand-off to the macOS switcher

    /// Step one, run at once: steps aside for the rest of the current ⌘ hold, so no new PinTab session
    /// can start. Returns false (and changes nothing) if the tap is not installed or ⌘ is already up.
    /// Releasing ⌘ ends the hand-off, so the next ⌘Tab is PinTab's again.
    func beginHandOff() -> Bool {
        guard isInstalled, Self.commandHeld else {
            Log.input.notice("Not handing off to the macOS switcher: ⌘ is no longer held")
            return false
        }
        filter.handOff()
        startHandOffWatch()
        Log.input.notice("Handed off to the macOS switcher until ⌘ is released")
        return true
    }

    /// Step two, run after PinTab's panel has closed: opens the macOS switcher by replaying ⌘Tab.
    /// Posting keystrokes uses the same Accessibility permission as the tap itself.
    func replayCommandTab() {
        guard isInstalled, filter.isHandingOff else {
            Log.input.notice("⌘ was released before the macOS switcher could open; not replaying ⌘Tab")
            return
        }
        guard CGPreflightPostEventAccess() else {
            Log.input.error("Cannot open the macOS switcher: not allowed to post keystrokes")
            return
        }
        replay = .posted
        // Keep ⇧ if it is held, so ⌘⇧Esc (or ⌘⇧S) opens the macOS switcher going backwards.
        let held = CGEventSource.flagsState(.combinedSessionState)
        let flags: CGEventFlags = held.contains(.maskShift) ? [.maskCommand, .maskShift] : .maskCommand
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(KeyCode.tab), keyDown: isDown)
            else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Decides whether a replayed event may continue to the system. The replay is dropped whole if the
    /// ⌘ release overtook it, so the macOS switcher never opens after the user has let go.
    fileprivate func admitReplay(isKeyDown: Bool) -> Bool {
        if isKeyDown {
            let admit = replay == .posted && filter.isHandingOff
            replay = admit ? .downAdmitted : .none
            if !admit { Log.input.notice("Dropped the replayed ⌘Tab: ⌘ was released first") }
            return admit
        }
        let admit = replay == .downAdmitted
        replay = .none
        return admit
    }

    private static var commandHeld: Bool {
        KeyModifiers(eventFlags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)).contains(.command)
    }

    /// Backs up the tap: ends the hand-off if ⌘ is up even though the tap never saw the release.
    private func startHandOffWatch() {
        stopHandOffWatch()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.filter.isHandingOff {
                    self.stopHandOffWatch()
                } else if !Self.commandHeld {
                    self.filter.endHandOff()
                    self.stopHandOffWatch()
                    Log.input.notice("Hand-off ended: ⌘ is up (release not seen by the tap)")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        handOffWatch = timer
    }

    private func stopHandOffWatch() {
        handOffWatch?.invalidate()
        handOffWatch = nil
    }

    // MARK: - Draining

    private func startDraining() {
        draining = true
        drainStarted = uptime()
        scheduleDrainCheck()
        Log.input.notice("Keeping the ⌘Tab event tap until swallowed keys are released")
    }

    /// Safety net for a key-up the tap never sees (secure input can hide it): finish once no owned key
    /// is physically down, and in any case after 10 s.
    private func scheduleDrainCheck() {
        drainTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.draining else { return }
                let stillHeld = self.filter.ownedKeys.contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
                if stillHeld && uptime() - self.drainStarted < 10 {
                    self.scheduleDrainCheck()
                } else {
                    self.finishDraining()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func stopDraining() {
        draining = false
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func finishDraining() {
        guard draining else { return }
        stopDraining()
        guard !enabled, isInstalled else { return }
        uninstall()
        onStateChange()
    }

    // MARK: - Tap lifecycle

    private func install() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Also happens when a rebuilt, re-signed binary still shows as allowed for its old signature.
            if !createFailureLogged {
                Log.input.error("CGEvent.tapCreate failed; waiting for Accessibility permission")
                createFailureLogged = true
            }
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Log.input.error("CFMachPortCreateRunLoopSource failed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        filter.reset()
        createFailureLogged = false
        isInstalled = true
        Log.input.notice("Installed ⌘Tab event tap")
        return true
    }

    private func uninstall() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        filter.reset()
        replay = .none
        stopHandOffWatch()
        isInstalled = false
        Log.input.notice("Removed ⌘Tab event tap")
    }

    /// Turns a tap macOS switched off back on. False if it stays off or trust is gone, in which case the
    /// caller tears it down so the poll can install a fresh one once permission is back.
    private func revive(_ port: CFMachPort, cause: StaticString) -> Bool {
        filter.forgetKeys()
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port), Self.isTrusted else {
            Log.input.notice("Event tap disabled (\(cause, privacy: .public)) and could not be re-enabled")
            return false
        }
        Log.input.notice("Event tap re-enabled (\(cause, privacy: .public))")
        return true
    }

    // MARK: - Trust polling

    // Keeps running while installed too: a revoked permission produces no reliable callback, and an active
    // tap that has lost permission must come out of the event path so typing is never held up by it.
    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard enabled else { return }
        let trusted = Self.isTrusted
        var changed = false
        if trusted != lastTrusted {
            lastTrusted = trusted
            Log.input.notice("Accessibility trust changed: \(trusted ? "granted" : "not granted", privacy: .public)")
            changed = true
        }
        if let port, !trusted || (!CGEvent.tapIsEnabled(tap: port) && !revive(port, cause: "found by poll")) {
            uninstall()
            changed = true
        }
        if !isInstalled && trusted && install() { changed = true }
        if changed { onStateChange() }
    }

    // MARK: - Callback (main thread)

    fileprivate func tapDisabled(byTimeout: Bool) {
        guard let port else { return }
        if revive(port, cause: byTimeout ? "timeout" : "user input") { return }
        uninstall()
        onStateChange()
    }

    /// Runs for every keyboard event system-wide, so it never logs ordinary keys.
    fileprivate func handle(_ kind: TapEventKind, keyCode: UInt16, modifiers: KeyModifiers, isRepeat: Bool) -> Bool {
        let decision = filter.decide(kind, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, phase: phase())
        if let action = decision.action {
            if case .cycle(let forward) = action, !isRepeat {
                Log.input.debug("Swallowed ⌘Tab forward=\(forward)")
            }
            onAction(action)
        }
        if draining && !filter.ownsKeys {
            // The last swallowed key is released; remove the tap once this callback has returned.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.filter.ownsKeys else { return }
                    self.finishDraining()
                }
            }
        }
        return decision.swallow
    }
}

/// C callback for the tap. The run-loop source is on the main run loop, so this always runs on the main thread.
nonisolated private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    // PinTab's own replayed ⌘Tab (a hand-off to the macOS switcher) bypasses the filter; it is only
    // dropped if the ⌘ release overtook it.
    if event.getIntegerValueField(.eventSourceUserData) == EventTap.syntheticMarker {
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let isKeyDown = type == .keyDown
        let admit = MainActor.assumeIsolated { owner.admitReplay(isKeyDown: isKeyDown) }
        return admit ? Unmanaged.passUnretained(event) : nil
    }
    let kind: TapEventKind
    switch type {
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    case .flagsChanged: kind = .flagsChanged
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        let byTimeout = type == .tapDisabledByTimeout
        MainActor.assumeIsolated { owner.tapDisabled(byTimeout: byTimeout) }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let modifiers = KeyModifiers(eventFlags: UInt(event.flags.rawValue))
    let swallow = MainActor.assumeIsolated {
        owner.handle(kind, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
