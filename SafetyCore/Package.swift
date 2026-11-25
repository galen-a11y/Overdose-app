// swift-tools-version:5.9
// SafetyCore holds the logic that must be right no matter what phone or sensor
// is in use: decoding oximeter packets and deciding when to check in or alert.
// It depends only on Foundation so it builds and tests on macOS and Linux.
import PackageDescription

let package = Package(
    name: "SafetyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SafetyCore", targets: ["SafetyCore"]),
    ],
    targets: [
        .target(name: "SafetyCore"),
        .testTarget(name: "SafetyCoreTests", dependencies: ["SafetyCore"]),
    ]
)
