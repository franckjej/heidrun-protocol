// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeidrunUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeidrunUI", targets: ["HeidrunUI"])
    ],
    dependencies: [
        .package(path: "../HeidrunCore")
    ],
    targets: [
        .target(
            name: "HeidrunUI",
            dependencies: [
                .product(name: "HeidrunCore", package: "HeidrunCore")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "HeidrunUITests",
            dependencies: ["HeidrunUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
