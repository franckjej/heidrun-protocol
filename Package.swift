// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeidrunCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeidrunCore", targets: ["HeidrunCore"]),
        .library(name: "HeidrunNIOClient", targets: ["HeidrunNIOClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(name: "HeidrunCore"),
        .target(
            name: "HeidrunNIOClient",
            dependencies: [
                "HeidrunCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .testTarget(name: "HeidrunCoreTests", dependencies: ["HeidrunCore"]),
        .testTarget(name: "HeidrunNIOClientTests", dependencies: ["HeidrunNIOClient"])
    ],
    swiftLanguageModes: [.v6]
)
