// swift-tools-version: 5.10

import PackageDescription
import Foundation

let noUpdater = ProcessInfo.processInfo.environment["PARROT_NO_UPDATER"] == "1"

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // On-device speaker diarization (CoreML pyannote pipeline). Pinned to
        // the exact validated revision: clustering on borderline calls is
        // numerically chaotic across library changes, so bumps must re-run
        // --diarize-test on a real multi-party recording (see DiarizationEngine).
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "5390df9752c8fc583596018360c5fd70d6fa6c75"),
        // Vendored SpeexDSP for acoustic echo cancellation. Kept in sync with
        // project.yml (the xcodegen source of truth) so `swift build` works too.
        .package(path: "Vendor/CSpeexDSP"),
        // Self-updating. Sparkle is a binary XCFramework, so the Makefile has
        // to copy it into Contents/Frameworks itself — `swift build` links it
        // but never embeds it (see the bundle step).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .target(name: "HostHelperProtocol", path: "Shared"),
        .executableTarget(name: "ParrotHostHelper", dependencies: ["HostHelperProtocol"], path: "HostHelper", exclude: ["Resources", "Info.plist"]),
        .executableTarget(
            name: "Parrot",
            dependencies: [
                "HostHelperProtocol",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "CSpeexDSP", package: "CSpeexDSP"),
            ] + (noUpdater ? [] : [.product(name: "Sparkle", package: "Sparkle")]),
            path: "Parrot",
            swiftSettings: noUpdater ? [.define("PARROT_NO_UPDATER")] : [],
            linkerSettings: [
                // The framework lives next to the executable in the bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
