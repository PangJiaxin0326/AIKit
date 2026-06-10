// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "VolcengineArkFoundationModels",
    platforms: [
        .iOS("26.5"),
        .macOS("26.5"),
        .visionOS("26.5"),
        .watchOS("27.0"),
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
