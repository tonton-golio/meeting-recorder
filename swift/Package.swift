// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "SpeakerMatchingCore",
            path: "SpeakerMatchingCore"
        ),
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                "SpeakerMatchingCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "Experiments",
            dependencies: [
                "SpeakerMatchingCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Experiments"
        ),
        .executableTarget(
            name: "SpeakerMatchingCoreChecks",
            dependencies: ["SpeakerMatchingCore"],
            path: "Checks/SpeakerMatchingCoreChecks"
        ),
    ]
)
