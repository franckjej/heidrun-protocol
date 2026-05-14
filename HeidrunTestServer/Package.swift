// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeidrunTestServer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "HeidrunTestServerKit", targets: ["HeidrunTestServerKit"]),
        .executable(name: "HeidrunTestServer", targets: ["HeidrunTestServer"])
    ],
    dependencies: [
        .package(path: "../HeidrunCore")
    ],
    targets: [
        .target(
            name: "HeidrunTestServerKit",
            dependencies: [
                .product(name: "HeidrunCore", package: "HeidrunCore")
            ]
        ),
        .executableTarget(
            name: "HeidrunTestServer",
            dependencies: [
                .product(name: "HeidrunCore", package: "HeidrunCore"),
                "HeidrunTestServerKit"
            ]
        ),
        .testTarget(
            name: "HeidrunTestServerKitTests",
            dependencies: [
                "HeidrunTestServerKit",
                .product(name: "HeidrunCore", package: "HeidrunCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
