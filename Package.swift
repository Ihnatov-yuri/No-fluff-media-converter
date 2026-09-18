// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoCompressor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VideoCompressorCore", targets: ["VideoCompressorCore"]),
        .executable(name: "VideoCompressor", targets: ["VideoCompressorApp"]),
        .executable(name: "VideoCompressorChecks", targets: ["VideoCompressorChecks"])
    ],
    targets: [
        .target(name: "VideoCompressorCore"),
        .executableTarget(
            name: "VideoCompressorApp",
            dependencies: ["VideoCompressorCore"],
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "VideoCompressorChecks",
            dependencies: ["VideoCompressorCore"]
        )
    ]
)
