// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "stt",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(
            name: "stt",
            targets: ["stt"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "stt",
            dependencies: [
                "FluidAudio",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "sttTests",
            dependencies: ["stt"]
        ),
    ]
)
