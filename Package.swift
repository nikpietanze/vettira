// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vettira",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VettiraCore", targets: ["VettiraCore"])
    ],
    targets: [
        .target(name: "VettiraCore"),
        .testTarget(name: "VettiraCoreTests", dependencies: ["VettiraCore"], resources: [.copy("Fixtures")]),
    ]
)
