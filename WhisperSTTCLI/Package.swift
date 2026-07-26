// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "whisper-stt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "whisper-stt", targets: ["whisper-stt"]),
    ],
    targets: [
        .target(name: "WhisperSTTCore"),
        .executableTarget(name: "whisper-stt", dependencies: ["WhisperSTTCore"]),
        .testTarget(name: "WhisperSTTCoreTests", dependencies: ["WhisperSTTCore"]),
    ]
)
