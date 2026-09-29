import Foundation
import os

/// Unified logging. Read with `make logs` (live) or
/// `log show --last 10m --predicate 'subsystem == "dev.local.PinTab"'` (notice level and above persist).
nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.local.PinTab"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let activation = Logger(subsystem: subsystem, category: "activation")
}

nonisolated func uptime() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
