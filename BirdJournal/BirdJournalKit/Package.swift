// swift-tools-version: 6.4

import PackageDescription

// BirdJournalKit holds the app's testable seams as separate modules.
//
// - Identification: audio windowing + BirdNET inference (ONNX Runtime). No toolkit dependency.
// - LensSession:    glasses session, lens page model, Display/Inputs wiring (Device Access Toolkit).
// - Pack:           species packs (bundled LA pack, downloadable regional packs).
// - Album:          saved sightings (SwiftData).
//
// The Device Access Toolkit ships iOS-only xcframeworks, so build and test this package through the
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
        .package(url: "https://github.com/facebook/meta-wearables-dat-ios", exact: "1.0.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(
            name: "Identification",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),
        .testTarget(
            name: "IdentificationTests",
            dependencies: [
                "Identification",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ]
        ),

        .target(
            name: "LensSession",
            dependencies: [
                .product(name: "MWDATCore", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATCamera", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATDisplay", package: "meta-wearables-dat-ios"),
                .product(name: "MWDATInputs", package: "meta-wearables-dat-ios"),
            ]
        ),
        // Mock Device Kit tests do not live here: `Wearables.configure()` reads the main bundle's name, version
        // and build number, and a hostless package test bundle has none, so `MockDeviceKit.enable()` traps.
        // Mock-device tests go in an app-hosted test target once the app carries its DAT Info.plist keys.
        .testTarget(name: "LensSessionTests", dependencies: ["LensSession"]),

        .target(name: "Pack"),
        .testTarget(name: "PackTests", dependencies: ["Pack"]),

        .target(name: "Album"),
        .testTarget(name: "AlbumTests", dependencies: ["Album"]),
    ],
    swiftLanguageModes: [.v6]
)
