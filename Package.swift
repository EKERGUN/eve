// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesToggle",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "WakeMatcher",
            path: "Sources/WakeMatcher"
        ),
        .executableTarget(
            name: "HermesToggle",
            dependencies: ["WakeMatcher"],
            path: "Sources/HermesToggle",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WakeMatcherTests",
            dependencies: ["WakeMatcher"],
            path: "Tests/WakeMatcherTests"
        )
    ]
)
