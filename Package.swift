// swift-tools-version: 6.0

import PackageDescription

// Phase 0: module scaffolding and contracts. No features, no audio, no
// playback. The topology below is the boundary enforcement mechanism: a
// module that needs another module's knowledge must declare the dependency
// here, and every declared dependency is visible in a diff.
//
//   SiriusXMCore      pure value types. Zero I/O. Depends on nothing.
//   SiriusXMNet       URLSession transport, retry policy, keychain storage.
//   SiriusXMProtocol  the only module that knows hosts, paths, and JSON keys.
//   SiriusXMPlayback  will own AVPlayer. Receives an opaque MediaHandoff.
//   SiriusXMUI        SwiftUI + @Observable. Never imports SiriusXMProtocol.
//   SiriusXMApp       the sole @MainActor composition root.
//   SiriusXMProbe     the Phase 0.5 research probe, kept runnable.
//
// SiriusXMUI deliberately omits SiriusXMProtocol from its dependency list.
// SiriusXMPlayback deliberately omits SiriusXMProtocol and SiriusXMNet, so
// there is no compile-time path by which a token could reach AVPlayer.
let package = Package(
    name: "SiriusXM",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SiriusXMCore"
        ),
        .target(
            name: "SiriusXMNet",
            dependencies: ["SiriusXMCore"]
        ),
        .target(
            name: "SiriusXMProtocol",
            dependencies: ["SiriusXMCore", "SiriusXMNet"]
        ),
        .executableTarget(
            name: "SiriusXMProbe",
            dependencies: ["SiriusXMCore", "SiriusXMNet", "SiriusXMProtocol"]
        ),
        .testTarget(
            name: "SiriusXMCoreTests",
            dependencies: ["SiriusXMCore"]
        ),
        .testTarget(
            name: "SiriusXMNetTests",
            dependencies: ["SiriusXMNet"]
        ),
        .testTarget(
            name: "SiriusXMProtocolTests",
            dependencies: ["SiriusXMProtocol"]
        ),
        .testTarget(
            name: "SiriusXMProbeTests",
            dependencies: ["SiriusXMProbe"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
