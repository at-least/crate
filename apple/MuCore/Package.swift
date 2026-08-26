// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MuCore",
    targets: [
        .target(name: "MuCore"),
        .testTarget(name: "MuCoreTests", dependencies: ["MuCore"]),
    ]
)
