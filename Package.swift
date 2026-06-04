// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Recorder",
    platforms: [
        // macOS 15+: the Synchronization module's `Atomic` (used by the
        // realtime-safe ring buffer in the system-audio tap) requires it.
        .macOS("15")
    ],
    targets: [
        .executableTarget(
            name: "Recorder",
            path: "Sources/Recorder",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
