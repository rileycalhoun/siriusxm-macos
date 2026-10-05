// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiriusXMProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SiriusXMProbe", path: "Sources/SiriusXMProbe"),
        .testTarget(name: "SiriusXMProbeTests", dependencies: ["SiriusXMProbe"], path: "Tests/SiriusXMProbeTests"),
    ],
    swiftLanguageModes: [.v6]
)
