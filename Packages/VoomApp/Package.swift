// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoomApp", targets: ["VoomApp"]),
    ],
    dependencies: [
        .package(path: "../VoomCore"),
    ],
    targets: [
        .target(
            name: "VoomApp",
            dependencies: ["VoomCore"]
        ),
    ]
)
