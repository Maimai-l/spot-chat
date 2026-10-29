// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpotCore", targets: ["SpotCore"]),
        .library(name: "SpotData", targets: ["SpotData"]),
        .library(name: "SpotAI", targets: ["SpotAI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/MacPaw/OpenAI", .upToNextMinor(from: "0.5.3")),
    ],
    targets: [
        .target(name: "SpotCore"),
        .target(
            name: "SpotData",
            dependencies: ["SpotCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "SpotAI",
            dependencies: ["SpotCore", .product(name: "OpenAI", package: "OpenAI")]
        ),
        .testTarget(name: "SpotCoreTests", dependencies: ["SpotCore"]),
        .testTarget(name: "SpotDataTests", dependencies: ["SpotData"]),
        .testTarget(name: "SpotAITests", dependencies: ["SpotAI"]),
    ]
)
