// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "VolcengineArkFoundationModels",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .visionOS("27.0"),
    ],
    products: [
        .library(
            name: "VolcengineArkFoundationModels",
            targets: ["VolcengineArkFoundationModels"]
        ),
    ],
    targets: [
        .target(
            name: "VolcengineArkFoundationModels",
            swiftSettings: swiftSettings
        ),
    ]
)
