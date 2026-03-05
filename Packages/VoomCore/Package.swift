// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoomCore", targets: ["VoomCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        .target(
            name: "VoomCore",
            dependencies: ["FluidAudio"]
        ),
    ]
)
