/// Durable identity of an application: its bundle identifier.
///
/// Process identifiers are never used as identity; they are temporary and can be reused.
public struct AppID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let bundleID: String

    public init(_ bundleID: String) {
        self.bundleID = bundleID
    }

    public var description: String { bundleID }

    public static func < (lhs: AppID, rhs: AppID) -> Bool {
        lhs.bundleID < rhs.bundleID
    }

    public init(from decoder: any Decoder) throws {
        bundleID = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bundleID)
    }
}
