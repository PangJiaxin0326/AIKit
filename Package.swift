// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AIKit",
    platforms: [
        .iOS("26.5"),
        .macOS("26.5"),
        .visionOS("26.5"),
    ],
    products: [
        .library(name: "AIKit", targets: ["AIKit"]),
        .library(name: "AIKitCore", targets: ["AIKitCore"]),
        .library(name: "AIKitCapability", targets: ["AIKitCapability"]),
        .library(name: "AIKitRuntime", targets: ["AIKitRuntime"]),
        .library(name: "AIKitSafety", targets: ["AIKitSafety"]),
        .library(name: "AIKitUI", targets: ["AIKitUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/PangJiaxin0326/MultiModalKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "AIKitCore",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitCapability",
            dependencies: ["AIKitCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitSafety",
            dependencies: ["AIKitCore", "AIKitCapability"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitRuntime",
            dependencies: ["AIKitCore", "AIKitCapability", "AIKitSafety"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitUI",
            dependencies: [
                "AIKitCore",
                "AIKitCapability",
                "AIKitRuntime",
                "AIKitSafety",
                .product(name: "MultiModalKit", package: "MultiModalKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKit",
            dependencies: [
                "AIKitCore",
                "AIKitCapability",
                "AIKitRuntime",
                "AIKitSafety",
                "AIKitUI",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitTestSupport",
            dependencies: ["AIKitCore", "AIKitCapability"],
            path: "Sources/AIKitTestSupport",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitCoreTests",
            dependencies: ["AIKitCore", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitCapabilityTests",
            dependencies: ["AIKitCapability", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitRuntimeTests",
            dependencies: ["AIKitRuntime", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitSafetyTests",
            dependencies: ["AIKitSafety", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitIntegrationTests",
            dependencies: ["AIKit", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
    ]
)
