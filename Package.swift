// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexMeter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CodexMeter"
        ),
        .testTarget(
            name: "CodexMeterTests",
            dependencies: ["CodexMeter"]
        )
    ],
    swiftLanguageModes: [.v5]
)
