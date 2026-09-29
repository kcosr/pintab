import Foundation

/// A saved pin. The name is remembered so a pin whose app is closed or uninstalled can still be shown.
public struct PinnedApp: Hashable, Codable, Sendable {
    public var id: AppID
    public var name: String

    public init(id: AppID, name: String) {
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppID.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id.bundleID
    }
}

/// Ordered pin membership. Insertion order is kept as a stable fallback order; it is not a
/// user-arranged switching order.
public struct PinList: Sendable, Equatable {
    public private(set) var pins: [PinnedApp]

    public init(_ pins: [PinnedApp] = []) {
        var seen = Set<AppID>()
        self.pins = pins.filter { !$0.id.bundleID.isEmpty && seen.insert($0.id).inserted }
    }

    public var ids: [AppID] { pins.map(\.id) }

    public func contains(_ id: AppID) -> Bool {
        pins.contains { $0.id == id }
    }

    public func name(of id: AppID) -> String? {
        pins.first { $0.id == id }?.name
    }

    /// Returns true when membership actually changed.
    @discardableResult
    public mutating func setPinned(_ id: AppID, name: String, pinned: Bool) -> Bool {
        if pinned {
            guard !contains(id), !id.bundleID.isEmpty else { return false }
            pins.append(PinnedApp(id: id, name: name))
            return true
        }
        let before = pins.count
        pins.removeAll { $0.id == id }
        return pins.count != before
    }

    /// Keeps the remembered name current. Never changes membership.
    public mutating func updateName(_ id: AppID, to name: String) {
        guard !name.isEmpty, let index = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[index].name = name
    }
}

/// Tolerant encoding of the preferences stored in UserDefaults. Malformed entries are dropped
/// individually; valid pins are never discarded because of a neighbouring bad entry.
public enum PreferencesCodec {
    public static func decodePins(_ data: Data?) -> PinList {
        guard let data else { return PinList() }
        guard let entries = try? JSONDecoder().decode([Lossy<PinEntry>].self, from: data) else { return PinList() }
        return PinList(entries.compactMap(\.value?.pin))
    }

    public static func encodePins(_ pins: PinList) -> Data {
        (try? JSONEncoder().encode(pins.pins)) ?? Data("[]".utf8)
    }

    /// Returns nil for missing, malformed, or no-longer-valid shortcuts.
    public static func decodeShortcut(_ data: Data?) -> Shortcut? {
        guard let data, let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return nil }
        return shortcut.validate() == nil ? shortcut : nil
    }

    public static func encodeShortcut(_ shortcut: Shortcut) -> Data {
        (try? JSONEncoder().encode(shortcut)) ?? Data()
    }
}

/// A stored pin: either a full record or, leniently, a bare bundle identifier string.
private struct PinEntry: Decodable {
    let pin: PinnedApp

    init(from decoder: any Decoder) throws {
        if let bundleID = try? decoder.singleValueContainer().decode(String.self) {
            pin = PinnedApp(id: AppID(bundleID), name: bundleID)
        } else {
            pin = try PinnedApp(from: decoder)
        }
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
