// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimPRCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimPRCore", targets: ["SimPRCore"]),
    ],
    targets: [
        .target(name: "SimPRCore"),
        .testTarget(
            name: "SimPRCoreTests",
            dependencies: ["SimPRCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
