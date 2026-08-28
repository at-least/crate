// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MuCore", targets: ["MuCore"]),
        .library(name: "MuKit", targets: ["MuKit"]),
    ],
    targets: [
        .target(name: "MuCore"),
        .target(name: "MuKit", dependencies: ["MuCore"]),
        .executableTarget(name: "PerfCheck", dependencies: ["MuCore"]),
        .testTarget(name: "MuCoreTests", dependencies: ["MuCore"]),
        .testTarget(name: "MuKitTests", dependencies: ["MuKit"]),
    ]
)
