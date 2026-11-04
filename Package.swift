// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SizeBerg",
    // macOS 26 is the first release with Liquid Glass; the app uses its SwiftUI APIs without availability checks.
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SizeBergCore"),
        .executableTarget(name: "sizeberg", dependencies: ["SizeBergCore"]),
        .executableTarget(name: "SizeBergApp", dependencies: ["SizeBergCore"]),
        .testTarget(name: "SizeBergCoreTests", dependencies: ["SizeBergCore"]),
    ],
    swiftLanguageModes: [.v5]
)
