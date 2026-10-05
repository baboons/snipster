// swift-tools-version: 6.0
import PackageDescription

// The Rust pixel core is built by `make core` (cargo) into core/target/release.
let rustLibDir = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "Snipster",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSnipsterCore", path: "Sources/CSnipsterCore"),
        .executableTarget(
            name: "Snipster",
            dependencies: ["CSnipsterCore"],
            path: "Sources/Snipster",
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir, "-Xlinker", "-dead_strip"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
