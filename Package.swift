// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesToggle",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HermesToggle",
            path: "Sources/HermesToggle",
            resources: [.process("Resources")]
        )
    ]
)
