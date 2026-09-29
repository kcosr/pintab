import AppKit
import PinTabCore

/// Activates the chosen app with public NSRunningApplication APIs and verifies the result.
///
/// PinTab's switcher panel never activates PinTab, so it cannot yield activation on the origin
/// app's behalf. The direct request is tried first; if macOS has not made the target frontmost
/// shortly afterwards, PinTab activates itself and hands activation over cooperatively.
final class Activator {
    private let apps: RunningApps
    private var attempt = 0
    /// False while a new switcher session or editor is open; the fallback must not steal its focus.
    var shouldIntervene: () -> Bool = { true }

    /// Delay before checking whether the direct request took effect.
    private let verifyDelay: TimeInterval = 0.25

    init(apps: RunningApps) {
        self.apps = apps
    }

    func activate(_ id: AppID) {
        guard let target = apps.instance(for: id) else {
            Log.activation.notice("Not activating \(id.bundleID, privacy: .public): no longer running")
            return
        }
        attempt += 1
        let current = attempt
        let started = uptime()
        let origin = NSWorkspace.shared.frontmostApplication?.processIdentifier
        apps.requestedActivation(id)

        if target.isHidden { target.unhide() }
        let accepted = target.activate(options: [])
        Log.activation.notice("Direct activation of \(id.bundleID, privacy: .public) returned \(accepted)")

        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.verify(id: id, target: target, origin: origin, attempt: current, started: started, fallbackUsed: false)
            }
        }
    }

    private func verify(id: AppID, target: NSRunningApplication, origin: pid_t?, attempt current: Int,
                        started: TimeInterval, fallbackUsed: Bool) {
        let elapsed = Int((uptime() - started) * 1000)
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == target.processIdentifier {
            Log.activation.notice(
                "\(id.bundleID, privacy: .public) is frontmost after \(elapsed) ms (fallback: \(fallbackUsed))")
            return
        }
        guard !fallbackUsed else {
            Log.activation.error(
                "\(id.bundleID, privacy: .public) is not frontmost after \(elapsed) ms; frontmost is \(front?.bundleIdentifier ?? "none", privacy: .public)")
            // Never leave focus stranded in PinTab, which has no windows to type into.
            if NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.hide(nil)
            }
            return
        }
        // Never fight the user: skip the fallback if a newer switch happened, a new session is open,
        // or focus has already moved somewhere other than the app being switched away from.
        guard current == attempt, !target.isTerminated, shouldIntervene(),
              front?.processIdentifier == origin
        else {
            Log.activation.notice("Skipping activation fallback for \(id.bundleID, privacy: .public)")
            return
        }
        Log.activation.notice(
            "Direct activation of \(id.bundleID, privacy: .public) not observed after \(elapsed) ms; trying cooperative handoff")
        NSApp.activate()
        NSApp.yieldActivation(to: target)
        if target.isHidden { target.unhide() }
        let accepted = target.activate(from: .current, options: [])
        Log.activation.notice("Cooperative activation returned \(accepted)")
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.verify(id: id, target: target, origin: origin, attempt: current, started: started, fallbackUsed: true)
            }
        }
    }
}
