// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeidrunTestServer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "HeidrunTestServer", targets: ["HeidrunTestServer"])
    ],
    dependencies: [
        .package(path: "../HeidrunCore")
    ],
    targets: [
        .executableTarget(
            name: "HeidrunTestServer",
            dependencies: [
                .product(name: "HeidrunCore", package: "HeidrunCore")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
