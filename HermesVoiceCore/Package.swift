// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HermesVoiceCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "HermesVoiceCore", targets: ["HermesVoiceCore"]),
    ],
    targets: [
        .target(name: "HermesVoiceCore"),
        .testTarget(name: "HermesVoiceCoreTests", dependencies: ["HermesVoiceCore"]),
    ]
)
