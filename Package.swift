// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SizeBerg",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SizeBergCore"),
        .executableTarget(name: "sizeberg", dependencies: ["SizeBergCore"]),
        .executableTarget(name: "SizeBergApp", dependencies: ["SizeBergCore"]),
        .testTarget(name: "SizeBergCoreTests", dependencies: ["SizeBergCore"]),
    ]
)
