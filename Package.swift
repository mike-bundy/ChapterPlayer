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
        .package(url: "https://github.com/mike-bundy/ChapterScript.git", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "ChapterPlayer",
            dependencies: ["ChapterScript"],
            path: "Sources/ChapterPlayer"
        )
    ]
)
