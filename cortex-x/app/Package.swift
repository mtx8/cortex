// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CortexX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CortexX",
            path: "Sources/CortexX"
        ),
        .testTarget(
            name: "CortexXTests",
            dependencies: ["CortexX"],
            path: "Tests/CortexXTests"
        ),
    ]
)
