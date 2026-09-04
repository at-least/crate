// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrateCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CrateCore", targets: ["CrateCore"]),
        .library(name: "CrateKit", targets: ["CrateKit"]),
    ],
    targets: [
        .target(name: "CrateCore"),
        .target(name: "CrateKit", dependencies: ["CrateCore"]),
        .executableTarget(name: "PerfCheck", dependencies: ["CrateCore"]),
        .testTarget(name: "CrateCoreTests", dependencies: ["CrateCore"]),
        .testTarget(name: "CrateKitTests", dependencies: ["CrateKit"]),
    ]
)
