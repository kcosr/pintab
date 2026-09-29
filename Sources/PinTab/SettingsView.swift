import Observation
import PinTabCore
import ServiceManagement
import SwiftUI

/// App-level state shown in Settings and the menu.
@Observable
final class AppState {
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
                LabeledContent("Shortcut") {
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
                Text("PinTab needs no special permissions. It registers one keyboard shortcut and does not read other keystrokes. It makes no network connections and stores only your pinned apps and shortcut.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pinSummary: String {
        switch preferences.pins.pins.count {
        case 0: return "No apps pinned"
        case 1: return "1 app pinned"
        case let count: return "\(count) apps pinned"
        }
    }

    private var shortcutHelp: String {
        guard let shortcut = preferences.shortcut else {
            return "Click Record Shortcut, then press the key combination you want, for example ⌘⌥Tab. It must include Command or Control."
        }
        let modifiers = shortcut.modifiers.symbols
        let key = KeyNames.name(for: shortcut.keyCode)
        return "Hold \(modifiers) and press \(key) to open the switcher. Press \(key) again to move right, add ⇧ to move left, and release \(modifiers) to switch. Press M or click Manage… to edit pins."
    }
}
