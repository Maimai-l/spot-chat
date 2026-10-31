// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpotCore", targets: ["SpotCore"]),
        .library(name: "SpotData", targets: ["SpotData"]),
        .library(name: "SpotAI", targets: ["SpotAI"]),
        .library(name: "SpotAgent", targets: ["SpotAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/MacPaw/OpenAI", .upToNextMinor(from: "0.5.3")),
        // The Agent Client Protocol (a Swift port of the official Kotlin SDK), for talking to dsh.
        .package(url: "https://github.com/aptove/swift-sdk", .upToNextMinor(from: "0.2.2")),
        // Apple's logging API; the app decides where the lines go. Later versions need a newer Swift than CI's.
        .package(url: "https://github.com/apple/swift-log", .upToNextMinor(from: "1.9.1")),
        // Used by the ACP SDK; held at the last version CI's Swift 6.1 can build.
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.2.1")),
    ],
    targets: [
        .target(name: "SpotCore", dependencies: [.product(name: "Logging", package: "swift-log")]),
        .target(
            name: "SpotData",
            dependencies: ["SpotCore", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "Logging", package: "swift-log")]
        ),
        .target(
            name: "SpotAI",
            dependencies: ["SpotCore", .product(name: "OpenAI", package: "OpenAI"), .product(name: "Logging", package: "swift-log")]
        ),
        .target(
            name: "SpotAgent",
            dependencies: [
                "SpotCore",
                .product(name: "ACP", package: "swift-sdk"),
                .product(name: "ACPModel", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "SpotCoreTests", dependencies: ["SpotCore"]),
        .testTarget(name: "SpotDataTests", dependencies: ["SpotData"]),
        .testTarget(name: "SpotAITests", dependencies: ["SpotAI", .product(name: "Logging", package: "swift-log")]),
    ]
)
