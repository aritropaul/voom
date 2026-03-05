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
    ],
    targets: [
        .target(
            name: "VoomMeetings",
            dependencies: ["VoomCore"]
        ),
    ]
)
