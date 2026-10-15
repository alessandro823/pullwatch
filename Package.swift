// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PullwatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PullwatchCore", targets: ["PullwatchCore"]),
    ],
    targets: [
        .target(name: "PullwatchCore"),
        .testTarget(name: "PullwatchCoreTests", dependencies: ["PullwatchCore"]),
    ]
)
