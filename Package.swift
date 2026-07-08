// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChapterPlayer",
    platforms: [
        .visionOS(.v26)
    ],
    products: [
        .library(
            name: "ChapterPlayer",
            targets: ["ChapterPlayer"]
        )
    ],
    dependencies: [
        // Local path during the source-trim rollout (needs ChapterScript
        // v0.5.0's sourceIn/sourceOut). Restore the tagged remote once
        // v0.5.0 is pushed: .package(url: "https://github.com/mike-bundy/ChapterScript.git", from: "0.5.0")
        .package(path: "../ChapterScript")
    ],
    targets: [
        .target(
            name: "ChapterPlayer",
            dependencies: ["ChapterScript"],
            path: "Sources/ChapterPlayer"
        )
    ]
)
