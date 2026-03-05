// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomMeetings",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoomMeetings", targets: ["VoomMeetings"]),
    ],
    dependencies: [
        .package(path: "../VoomCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        .target(
            name: "VoomMeetings",
            dependencies: ["VoomCore", "FluidAudio"]
        ),
    ]
)
