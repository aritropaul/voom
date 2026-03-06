// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoomAI", targets: ["VoomAI"]),
    ],
    dependencies: [
        .package(path: "../VoomCore"),
    ],
    targets: [
        .target(
            name: "VoomAI",
            dependencies: ["VoomCore"]
        ),
    ]
)
