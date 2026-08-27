// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MuCore", targets: ["MuCore"]),
    ],
    targets: [
        .target(name: "MuCore"),
        .testTarget(name: "MuCoreTests", dependencies: ["MuCore"]),
    ]
)
