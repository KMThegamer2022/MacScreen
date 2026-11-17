// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacScreen",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CVD", path: "Sources/CVD"),
        .executableTarget(
            name: "MacScreen",
            dependencies: ["CVD"],
            path: "Sources/MacScreen"
        ),
    ]
)
