// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpotCore", targets: ["SpotCore"]),
    ],
    targets: [
        .target(name: "SpotCore"),
        .testTarget(name: "SpotCoreTests", dependencies: ["SpotCore"]),
    ]
)
