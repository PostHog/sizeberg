// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SizeBerg",
    // macOS 26 is the first release with Liquid Glass; the app uses its SwiftUI APIs without availability checks.
    platforms: [.macOS(.v26)],
    dependencies: [
        // Updates for Developer ID builds. Exact, so a release never picks up an updater nobody tested.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "SizeBergCore"),
        .executableTarget(name: "sizeberg", dependencies: ["SizeBergCore"]),
        .executableTarget(
            name: "SizeBergApp",
            dependencies: ["SizeBergCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "SizeBergCoreTests", dependencies: ["SizeBergCore"]),
    ],
    swiftLanguageModes: [.v5]
)
