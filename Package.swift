// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeidrunCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeidrunCore", targets: ["HeidrunCore"]),
        .library(name: "HeidrunNIOClient", targets: ["HeidrunNIOClient"]),
        .executable(name: "heidrun", targets: ["heidrun"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
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
        // Cross-platform CLI on top of NIOHotlineClient — the
        // "HX-on-modern-stack" entry. Stays in this repo so it's tied
        // to the same protocol revision as the NIO transport it uses.
        .executableTarget(
            name: "heidrun",
            dependencies: [
                "HeidrunNIOClient",
                "HeidrunCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "HeidrunCoreTests", dependencies: ["HeidrunCore"]),
        .testTarget(name: "HeidrunNIOClientTests", dependencies: ["HeidrunNIOClient", "HeidrunCore"])
    ],
    swiftLanguageModes: [.v6]
)
