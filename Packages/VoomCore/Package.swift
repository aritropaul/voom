// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoomCore", targets: ["VoomCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "VoomCore",
            dependencies: ["WhisperKit"]
        ),
    ]
)
