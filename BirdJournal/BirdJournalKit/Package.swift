// swift-tools-version: 6.4

import PackageDescription

// BirdJournalKit holds the app's testable seams as separate modules.
//
// - Identification: audio windowing + BirdNET inference (ONNX Runtime). No UI, no toolkit dependency. Its
//                   `Models` resource folder is a symlink to the repo's `models/` directory (populated by
//                   `scripts/download-models.sh`), so the model files ship inside the package's resource bundle.
// - LensSession:    pure lens page state machine. No toolkit dependency; unit-tested without the glasses.
// - Pack:           species packs (bundled LA pack, downloadable regional packs).
// - Album:          saved sightings (SwiftData).
//
// The Device Access Toolkit is linked by the app target only, where the thin glasses adapter lives
// (docs/spec-v1-glasses-bird-id.md, "Architecture: three modules behind two seams"). Mock Device Kit smoke
// tests need an app-hosted test target: `Wearables.configure()` reads the main bundle's name, version and
// build number, which a hostless package test bundle lacks, so `MockDeviceKit.enable()` traps there.
//
// ONNX Runtime ships a binary framework built for iOS, so build and test this package through the
// `BirdJournalKit-Package` scheme on an iOS simulator (`scripts/build-and-test.sh`), not with `swift test` on macOS.
let package = Package(
    name: "BirdJournalKit",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "Identification", targets: ["Identification"]),
        .library(name: "LensSession", targets: ["LensSession"]),
        .library(name: "Pack", targets: ["Pack"]),
        .library(name: "Album", targets: ["Album"]),
    ],
    dependencies: [
        .package(url: "https://github.com/lightsailvr/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "Identification",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            resources: [.copy("Models")]
        ),
        .testTarget(
            name: "IdentificationTests",
            dependencies: [
                "Identification",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            resources: [.copy("Fixtures")]
        ),

        .target(name: "LensSession"),
        .testTarget(name: "LensSessionTests", dependencies: ["LensSession"]),

        .target(name: "Pack"),
        .testTarget(name: "PackTests", dependencies: ["Pack"]),

        .target(name: "Album"),
        .testTarget(name: "AlbumTests", dependencies: ["Album"]),
    ],
    swiftLanguageModes: [.v6]
)
