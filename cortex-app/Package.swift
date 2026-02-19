// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CortexApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CortexCore", targets: ["CortexCore"]),
        .executable(name: "CortexApp", targets: ["CortexApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CortexCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "CortexApp",
            dependencies: ["CortexCore"]
        ),
        .testTarget(
            name: "CortexCoreTests",
            dependencies: ["CortexCore"]
        ),
    ]
)
