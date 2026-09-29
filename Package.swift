// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PinTab",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: selection, ordering, shortcuts, preferences. Foundation only, so it tests without a GUI.
        .target(name: "PinTabCore"),
        .executableTarget(
            name: "PinTab",
            dependencies: ["PinTabCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "PinTabCoreTests", dependencies: ["PinTabCore"]),
    ]
)
