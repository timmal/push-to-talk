// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HoldSpeak",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HoldSpeakCore", targets: ["HoldSpeakCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "HoldSpeakCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Core"
        ),
        .testTarget(
            name: "HoldSpeakCoreTests",
            dependencies: ["HoldSpeakCore"],
            path: "Tests"
        ),
    ]
)
