// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AIKit",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .visionOS("27.0"),
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
        // Use sibling checkouts so the AIKit stack builds against the packages
        // updated in lockstep during local development.
        .package(path: "../AIToolKit"),
        .package(path: "../MultiModalKit"),
        .package(path: "../UICollection"),
        .package(path: "../VolcengineArkFoundationModels"),
    ],
    targets: [
        .target(
            name: "AIKitCore",
            dependencies: [
                .product(
                    name: "VolcengineArkFoundationModels",
                    package: "VolcengineArkFoundationModels"
                ),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitCapability",
            dependencies: [
                .product(name: "AIToolKit", package: "AIToolKit"),
                "AIKitCore",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitSafety",
            dependencies: [
                .product(name: "AIToolKit", package: "AIToolKit"),
                "AIKitCore",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitRuntime",
            dependencies: [
                "AIKitCore",
                "AIKitCapability",
                "AIKitSafety",
                .product(
                    name: "VolcengineArkFoundationModels",
                    package: "VolcengineArkFoundationModels"
                ),
            ],
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
                .product(
                    name: "UICollection",
                    package: "UICollection",
                    condition: .when(platforms: [.iOS])
                )
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKit",
            dependencies: [
                .product(name: "AIToolKit", package: "AIToolKit"),
                .product(
                    name: "VolcengineArkFoundationModels",
                    package: "VolcengineArkFoundationModels"
                ),
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
            dependencies: [
                "AIKit",
                "AIKitCore",
                "AIKitCapability",
                "AIKitRuntime",
                "AIKitSafety",
                "AIKitTestSupport",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
