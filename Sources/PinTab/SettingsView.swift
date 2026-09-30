import Observation
import PinTabCore
import ServiceManagement
import SwiftUI

enum CommandTabStatus {
    case off
    /// Turned on, but PinTab is not (or no longer) trusted for Accessibility.
    case needsPermission
    case active
}

/// App-level state shown in Settings and the menu.
@Observable
final class AppState {
    var commandTabStatus: CommandTabStatus = .off
    var isPaused = false
    var isRecordingShortcut = false
    /// Why the saved shortcut is not currently registered, if it failed.
    var registrationError: String?
    /// Feedback from the most recent recording attempt.
    var recorderMessage: String?
    var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    var loginItemError: String?
}

struct SettingsActions: Sendable {
    var beginRecording: @MainActor @Sendable () -> Void
    var endRecording: @MainActor @Sendable () -> Void
    var changeShortcut: @MainActor @Sendable (Shortcut) -> String?
    var setPaused: @MainActor @Sendable (Bool) -> Void
    var setUseCommandTab: @MainActor @Sendable (Bool) -> Void
    var openAccessibilitySettings: @MainActor @Sendable () -> Void
    var setLaunchAtLogin: @MainActor @Sendable (Bool) -> Void
    var managePins: @MainActor @Sendable () -> Void
}

struct SettingsView: View {
    let preferences: Preferences
    let state: AppState
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Switcher Shortcut") {
                Toggle(isOn: Binding(get: { preferences.useCommandTab }, set: { actions.setUseCommandTab($0) })) {
                    Text("Use ⌘Tab")
                    Text("Replaces the macOS app switcher while PinTab runs. Needs Accessibility permission.")
                }
                if preferences.useCommandTab {
                    commandTabStatus
                }
                LabeledContent(preferences.useCommandTab ? "Other shortcut" : "Shortcut") {
                    ShortcutRecorder(
                        shortcut: preferences.shortcut,
                        onBegin: actions.beginRecording,
                        onEnd: actions.endRecording,
                        onCapture: actions.changeShortcut,
                        onError: { state.recorderMessage = $0 }
                    )
                    .frame(width: 190, height: 28)
                }
                if let message = state.recorderMessage ?? state.registrationError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let advisory = preferences.shortcut?.advisory {
                    Label(advisory, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Text(shortcutHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Pinned Apps") {
                LabeledContent(pinSummary) {
                    Button("Manage Pinned Apps…", action: actions.managePins)
                }
                Text("Only running apps can be pinned. Pinned apps that are not running stay pinned and are hidden from the switcher until they run again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("General") {
                Toggle("Pause PinTab", isOn: Binding(get: { state.isPaused }, set: { actions.setPaused($0) }))
                Toggle("Open at login", isOn: Binding(
                    get: { state.loginItemStatus == .enabled || state.loginItemStatus == .requiresApproval },
                    set: { actions.setLaunchAtLogin($0) }))
                if state.loginItemStatus == .requiresApproval {
                    Text("Approve PinTab in System Settings › General › Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = state.loginItemError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Privacy") {
                Text(privacyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var commandTabStatus: some View {
        switch state.commandTabStatus {
        case .active:
            Label("⌘Tab is active. In password fields and other secure text entry, ⌘Tab briefly falls back to the macOS switcher.",
                  systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .needsPermission:
            VStack(alignment: .leading, spacing: 8) {
                Label("Turn on PinTab in System Settings › Privacy & Security › Accessibility.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Each new PinTab build needs this again: if PinTab is already listed, remove it with − and turn it on again. ⌘Tab starts working as soon as it is allowed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings", action: actions.openAccessibilitySettings)
            }
            .font(.callout)
        case .off:
            EmptyView()
        }
    }

    private var privacyText: String {
        let base = "PinTab makes no network connections and stores only your pinned apps and shortcut settings."
        if preferences.useCommandTab {
            return "⌘Tab mode uses Accessibility permission to intercept ⌘Tab before macOS does. PinTab acts only on ⌘Tab and on keys pressed while its switcher is open, and never records or logs typing. " + base
        }
        return "PinTab needs no special permissions. It registers one keyboard shortcut and does not read other keystrokes. " + base
    }

    private var pinSummary: String {
        switch preferences.pins.pins.count {
        case 0: return "No apps pinned"
        case 1: return "1 app pinned"
        case let count: return "\(count) apps pinned"
        }
    }

    private var shortcutHelp: String {
        if preferences.useCommandTab {
            let other = preferences.shortcut.map { " \(KeyNames.display($0)) works the same way and needs no permission." } ?? ""
            return "Hold ⌘ and press Tab to open the switcher. Press Tab again to move right, add ⇧ to move left, and release ⌘ to switch. Press M or click ⋯ to edit pins, or P or ⏸ to pause PinTab and use the macOS switcher." + other
        }
        guard let shortcut = preferences.shortcut else {
            return "Click Record Shortcut, then press the key combination you want, for example ⌘⌥Tab. It must include Command or Control."
        }
        let modifiers = shortcut.modifiers.symbols
        let key = KeyNames.name(for: shortcut.keyCode)
        return "Hold \(modifiers) and press \(key) to open the switcher. Press \(key) again to move right, add ⇧ to move left, and release \(modifiers) to switch. Press M or click ⋯ to edit pins, or P or ⏸ to pause PinTab and use the macOS switcher."
    }
}
