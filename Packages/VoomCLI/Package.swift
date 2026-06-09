// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoomCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "voom", targets: ["voom"]),
    ],
    dependencies: [
        .package(path: "../VoomCore"),
        .package(path: "../VoomApp"),
    ],
    targets: [
        .executableTarget(
            name: "voom",
            dependencies: ["VoomCore", "VoomApp"]
        ),
    ]
)
