// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoMoWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MoMoWhisper", targets: ["MoMoWhisper"])
    ],
    targets: [
        .target(
            name: "MoMoWhisperSessionCore",
            path: "Sources/MoMoWhisperSessionCore"
        ),
        .executableTarget(
            name: "MoMoWhisper",
            dependencies: ["MoMoWhisperSessionCore"],
            path: "Sources/MoMoWhisper"
        ),
        .testTarget(
            name: "MoMoWhisperTests",
            dependencies: ["MoMoWhisperSessionCore"],
            path: "Tests/MoMoWhisperTests"
        ),
        .executableTarget(
            name: "MoMoWhisperLifecycleTestRunner",
            dependencies: ["MoMoWhisperSessionCore"],
            path: "Tests/MoMoWhisperLifecycleTestRunner"
        )
    ]
)
