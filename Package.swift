// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "octave-camo",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // The library is what the iOS app imports; the CLI is a thin wrapper around it.
        .library(name: "OctaveCamoKit", targets: ["OctaveCamoKit"]),
        .library(name: "OctaveCamoIO", targets: ["OctaveCamoIO"]),
        .executable(name: "octave-camo", targets: ["octave-camo"]),
        .executable(name: "octave-camo-wasm", targets: ["OctaveCamoWasm"]),
    ],
    targets: [
        // Pure DSP, no Foundation (libc math only): builds for iOS, macOS, Linux and WebAssembly.
        .target(name: "OctaveCamoKit"),
        // File I/O (WAV) on Foundation, for the CLI and tests.
        .target(name: "OctaveCamoIO", dependencies: ["OctaveCamoKit"]),
        .executableTarget(name: "octave-camo", dependencies: ["OctaveCamoKit", "OctaveCamoIO"]),
        // WebAssembly exports for the web app (a WASI reactor; see its main.swift).
        .executableTarget(name: "OctaveCamoWasm", dependencies: ["OctaveCamoKit"]),
        .testTarget(name: "OctaveCamoKitTests", dependencies: ["OctaveCamoKit", "OctaveCamoIO"]),
    ]
)
