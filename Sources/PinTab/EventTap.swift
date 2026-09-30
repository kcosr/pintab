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

    private var enabled = false
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var pollTimer: Timer?
    private var lastTrusted: Bool?
    private var createFailureLogged = false
    private var filter = CommandTabFilter()

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
        guard !enabled else { return }
        enabled = true
        let trusted = Self.isTrusted
        lastTrusted = trusted
        if !(trusted && install()) {
            Log.input.notice("Waiting for Accessibility permission to install the ⌘Tab event tap")
        }
        startPolling()
        if isInstalled { onStateChange() }
    }

    /// Removes the tap (if any), stops polling. Idempotent.
    func disable() {
        enabled = false
        stopPolling()
        lastTrusted = nil
        createFailureLogged = false
        filter.reset()
        guard isInstalled else { return }
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
        isInstalled = false
        Log.input.notice("Removed ⌘Tab event tap")
    }

    /// Turns a tap macOS switched off back on. False if it stays off or trust is gone, in which case the
    /// caller tears it down so the poll can install a fresh one once permission is back.
    private func revive(_ port: CFMachPort, cause: StaticString) -> Bool {
        filter.reset()
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
        return decision.swallow
    }
}

/// C callback for the tap. The run-loop source is on the main run loop, so this always runs on the main thread.
nonisolated private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
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
