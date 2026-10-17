// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SyncForgeKit",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "SyncForgeCore", targets: ["SyncForgeCore"]),
        .executable(name: "sfctl", targets: ["sfctl"]),
    ],
    targets: [
        // Real-time kernel (C11): ring buffer, renderer, resampler, filters, mic recorder.
        .target(
            name: "SyncForgeRT",
            cSettings: [.define("NDEBUG", .when(configuration: .release))],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Device management, capture, engine coordination, DSP design, calibration, profiles.
        .target(
            name: "SyncForgeCore",
            dependencies: ["SyncForgeRT"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        // Command-line tool for headless hardware validation.
        .executableTarget(name: "sfctl", dependencies: ["SyncForgeCore"]),
        .target(name: "SyncForgeRTTestSupport", dependencies: ["SyncForgeRT"],
                path: "Tests/SyncForgeRTTestSupport",
                cSettings: [.headerSearchPath("../../Sources/SyncForgeRT")]),
        .testTarget(name: "SyncForgeCoreTests", dependencies: ["SyncForgeCore", "SyncForgeRT", "SyncForgeRTTestSupport"]),
    ]
)
