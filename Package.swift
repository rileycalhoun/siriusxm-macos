// swift-tools-version: 6.0

import PackageDescription

// Phase 0.5 research spike: determine how SiriusXM session credentials can
// actually be acquired. Not the app. No audio, no playback, no UI.
let package = Package(
    name: "SiriusXMProbe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SiriusXMProbe"
        ),
    ],
    swiftLanguageModes: [.v6]
)
