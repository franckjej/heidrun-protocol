// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeidrunCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeidrunCore", targets: ["HeidrunCore"])
    ],
    targets: [
        .target(name: "HeidrunCore"),
        .testTarget(name: "HeidrunCoreTests", dependencies: ["HeidrunCore"])
    ],
    swiftLanguageModes: [.v6]
)
