// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoMoWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MoMoWhisper", targets: ["MoMoWhisper"]),
        .library(name: "MoMoWhisperSummaryCore", targets: ["MoMoWhisperSummaryCore"])
    ],
    targets: [
        .target(
            name: "MoMoWhisperSessionCore",
            path: "Sources/MoMoWhisperSessionCore"
        ),
        .target(
            name: "MoMoWhisperSummaryCore",
            path: "Sources/MoMoWhisperSummaryCore"
        ),
        .executableTarget(
            name: "MoMoWhisper",
            dependencies: ["MoMoWhisperSessionCore", "MoMoWhisperSummaryCore"],
            path: "Sources/MoMoWhisper"
        ),
        .testTarget(
            name: "MoMoWhisperTests",
            dependencies: ["MoMoWhisperSessionCore"],
            path: "Tests/MoMoWhisperTests"
        ),
        .testTarget(
            name: "MoMoWhisperSummaryCoreTests",
            dependencies: ["MoMoWhisperSummaryCore"],
            path: "Tests/MoMoWhisperSummaryCoreTests"
        ),
        .executableTarget(
            name: "MoMoWhisperSummaryCoreTestRunner",
            dependencies: ["MoMoWhisperSummaryCore"],
            path: "Tests/MoMoWhisperSummaryCoreTestRunner"
        ),
        .executableTarget(
            name: "MoMoWhisperLifecycleTestRunner",
            dependencies: ["MoMoWhisperSessionCore"],
            path: "Tests/MoMoWhisperLifecycleTestRunner"
        )
    ]
)
