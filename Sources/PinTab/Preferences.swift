import Foundation
import Observation
import PinTabCore

/// Durable settings: pinned app identities and the switcher shortcut. Nothing else is stored.
@Observable
final class Preferences {
    private enum Key {
        static let pins = "pins"
        static let shortcut = "shortcut"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pins: PinList
    private(set) var shortcut: Shortcut?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = PreferencesCodec.decodePins(defaults.data(forKey: Key.pins))
        shortcut = PreferencesCodec.decodeShortcut(defaults.data(forKey: Key.shortcut))
    }

    func setPinned(_ id: AppID, name: String, pinned: Bool) {
        guard pins.setPinned(id, name: name, pinned: pinned) else { return }
        Log.app.notice("\(pinned ? "Pinned" : "Unpinned", privacy: .public) \(id.bundleID, privacy: .public)")
        savePins()
    }

    func updateName(_ id: AppID, to name: String) {
        guard pins.contains(id), pins.name(of: id) != name else { return }
        pins.updateName(id, to: name)
        savePins()
    }

    func setShortcut(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        if let shortcut {
            defaults.set(PreferencesCodec.encodeShortcut(shortcut), forKey: Key.shortcut)
        } else {
            defaults.removeObject(forKey: Key.shortcut)
        }
    }

    private func savePins() {
        defaults.set(PreferencesCodec.encodePins(pins), forKey: Key.pins)
    }
}
