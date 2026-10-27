// swift-tools-version: 5.9
import PackageDescription

// Vendored sherpa-onnx runtime (v1.13.8, darwin arm64) for on-device
// SenseVoiceSmall + Silero VAD transcription. See Vendor/sherpa/NOTICE.md.
//
// The dylibs are prebuilt with `@rpath/...` install names, so the produced
// executables need two LC_RPATH entries:
//   - the Vendor/sherpa directory (development: `swift run`, `.build/...`)
//   - `@loader_path/../Resources/sherpa` (FocusVoice.app bundle layout)
//
// The vendored path is resolved from this manifest's own location (no
// `import Foundation`: SwiftPM compiles manifests with a clang module cache that
// may be read-only in sandboxed build environments, so the manifest must stay
// dependency-free).
let packageDirectory = String(#filePath.dropLast("Package.swift".count))
let sherpaVendorDirectory = packageDirectory + "Vendor/sherpa"

let sherpaLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L", sherpaVendorDirectory,
        "-lsherpa-onnx-c-api",
        "-Xlinker", "-rpath", "-Xlinker", sherpaVendorDirectory,
        "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Resources/sherpa",
    ]),
]

let package = Package(
    name: "FocusVoice",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FocusVoice", targets: ["FocusVoice"]),
        .executable(name: "SenseVoiceProbe", targets: ["SenseVoiceProbe"]),
    ],
    targets: [
        .target(
            name: "CSherpa",
            path: "Sources/CSherpa",
            publicHeadersPath: "include",
            linkerSettings: sherpaLinkerSettings
        ),
        .executableTarget(
            name: "FocusVoice",
            dependencies: ["CSherpa"],
            path: "Sources/FocusVoice",
            linkerSettings: sherpaLinkerSettings
        ),
        // Development tool: exercises the CSherpa shim against real models.
        //   swift run -c release SenseVoiceProbe [model-dir] [audio.wav]
        .executableTarget(
            name: "SenseVoiceProbe",
            dependencies: ["CSherpa"],
            path: "Sources/SenseVoiceProbe",
            linkerSettings: sherpaLinkerSettings
        ),
    ]
)
