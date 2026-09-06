// swift-tools-version: 6.4
import Foundation
import PackageDescription

let swiftSettings: [SwiftSetting] = [
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
        .library(name: "AIKitProviders", targets: ["AIKitProviders"]),
    ],
    dependencies: [
        ProcessInfo.processInfo.environment["SWIFTPACKAGES_USE_LOCAL_DEPENDENCIES"] == "1"
            ? .package(path: "../AIToolKit")
            : .package(url: "https://github.com/PangJiaxin0326/AIToolKit.git",
                       revision: "417c8023f9d99a6e739dc686c577b62729e71f31"),
        ProcessInfo.processInfo.environment["SWIFTPACKAGES_USE_LOCAL_DEPENDENCIES"] == "1"
            ? .package(path: "../MultiModalKit")
            : .package(url: "https://github.com/PangJiaxin0326/MultiModalKit.git",
                       revision: "c8711adb6c3bea390fb1c21fd192f577857c50ad"),
        ProcessInfo.processInfo.environment["SWIFTPACKAGES_USE_LOCAL_DEPENDENCIES"] == "1"
            ? .package(path: "../UICollection")
            : .package(url: "https://github.com/PangJiaxin0326/UICollection.git",
                       revision: "6552495b008b2896e31f6054137de12bccb016dd"),
        ProcessInfo.processInfo.environment["SWIFTPACKAGES_USE_LOCAL_DEPENDENCIES"] == "1"
            ? .package(path: "../VolcengineArkFoundationModels")
            : .package(url: "https://github.com/PangJiaxin0326/VolcengineArkFoundationModels.git",
                       revision: "f538c10caf8d0af848643049fcd67729eddc0f1b"),
    ],
    targets: [
        .target(
            name: "AIKitCore",
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
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AIKitProviders",
            dependencies: [
                "AIKitCore", "AIKitRuntime", "AIKitCapability", "AIKitSafety",
                .product(name: "VolcengineArkFoundationModels", package: "VolcengineArkFoundationModels"),
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
                "AIKitProviders",
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
            dependencies: ["AIKitCore", "AIKitProviders", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitCapabilityTests",
            dependencies: ["AIKitCapability", "AIKitTestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AIKitRuntimeTests",
            dependencies: ["AIKitRuntime", "AIKitProviders", "AIKitTestSupport"],
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
