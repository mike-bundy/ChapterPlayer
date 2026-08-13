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
        // Remote branch-tracking so downstream apps (SharedVisions) can
        // consume ChapterPlayer straight from GitHub. Repos that need the
        // in-development ChapterScript (Maestro) keep working: their local
        // ../ChapterScript package reference OVERRIDES this remote by
        // package identity — the standard local-override workflow. Pin to
        // a tagged version once the format settles.
        .package(url: "https://github.com/mike-bundy/ChapterScript.git", branch: "main")
    ],
    targets: [
        .target(
            name: "ChapterPlayer",
            dependencies: ["ChapterScript"],
            path: "Sources/ChapterPlayer"
        )
    ]
)
