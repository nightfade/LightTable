// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LightTable",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightTable", targets: ["LightTableApp"]),
        .executable(name: "lighttable-cli", targets: ["LightTableCLI"]),
        .executable(name: "lighttable-selftest", targets: ["LightTableSelfTest"]),
        .executable(name: "travelcut-selftest", targets: ["TravelCutSelfTest"]),
    ],
    targets: [
        // Shared base: paths, external tools, supervised child processes, media scan.
        .target(name: "LightTableKit"),
        // Video highlights and photo grouping, moved from TravelCut 0.8.0.
        .target(
            name: "TravelCutCore",
            dependencies: ["LightTableKit"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreML"),
                .linkedFramework("SoundAnalysis"),
            ]
        ),
        // Gyroflow stabilization and LUT grading, rewritten from batch-gyroflow.
        .target(name: "Stabilize", dependencies: ["LightTableKit"]),
        // Shooting-habit statistics and HTML report, rewritten from photo-habits.
        .target(name: "Habits", dependencies: ["LightTableKit", "TravelCutCore"]),
        .executableTarget(
            name: "LightTableApp",
            dependencies: ["LightTableKit", "TravelCutCore", "Stabilize", "Habits"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "LightTableCLI",
            dependencies: ["LightTableKit", "TravelCutCore", "Stabilize", "Habits"]
        ),
        .executableTarget(
            name: "LightTableSelfTest",
            dependencies: ["LightTableKit", "Stabilize", "Habits"]
        ),
        .executableTarget(name: "TravelCutSelfTest", dependencies: ["TravelCutCore"]),
    ],
    swiftLanguageModes: [.v5]
)
