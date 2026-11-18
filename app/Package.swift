// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StoryAudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StoryAudio",
            path: "Sources/StoryAudio",
            resources: [
                .copy("Resources/tts_worker.py"),
                .copy("Resources/catalog.json"),
                .copy("Resources/setup_runtime.sh"),
            ]
        )
    ]
)
