// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "octave-camo",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // The library is what the iOS app imports; the CLI is a thin wrapper around it.
        .library(name: "OctaveCamoKit", targets: ["OctaveCamoKit"]),
        .executable(name: "octave-camo", targets: ["octave-camo"]),
    ],
    targets: [
        .target(name: "OctaveCamoKit"),
        .executableTarget(name: "octave-camo", dependencies: ["OctaveCamoKit"]),
        .testTarget(name: "OctaveCamoKitTests", dependencies: ["OctaveCamoKit"]),
    ]
)
