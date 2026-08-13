# ChapterPlayer

The open source visionOS runtime that plays [ChapterScript](https://github.com/mike-bundy/ChapterScript) documents. It bundles the sequence engine, spatial audio and video managers, entity factory, gate detection, and live-development client into a single Swift package, so a consuming app only needs to ship its UI, content, and product-specific extensions.

ChapterPlayer is the same runtime that powers playback in [Maestro](https://maestrostud.io), the commercial authoring suite. Website: [chapterscript.com](https://chapterscript.com).

## What's in the package

- **`SequenceEngine`** — the declarative sequence/step choreographer. Always resets entities on sequence change; pluggable executor protocols for entity / audio / video / attachment / effect actions.
- **`GateDetectionController`** — holds a step until its gate resolves (tap, gaze, approach, grab, or timeout), behind the `GateDetecting` protocol.
- **`SpatialAudioManager`** — `AVAudioEngine`-based channel system with audio buses, ducking rules, audio zones, and loop configs.
- **`VideoPlaybackManager`** — per-channel `AVPlayer` orchestrator: flat scene panels, attachment-based SwiftUI overlays, and 360°/180° immersive skybox playback via `VideoPlayerComponent`.
- **`EntityFactory`** + **`DocumentEntityLoader`** — build RealityKit entities for ChapterScript `EntityDefinition`s (primitives, USDZs, text, lights, video panels) and materialize a document's entities into the immersive scene, registered with the executors.
- **`BackdropCueDriver`** — drives sequence backdrop presentation behind the `BackdropCuePresenting` protocol.
- **`MotionCurveEvaluator`** — a thin delegate over ChapterScript's canonical `MotionCurveSampling`, so playback matches editors' scrub previews, motion trails, and graph rendering exactly.
- **Experience providers + media resolvers** — `BundledExperienceProvider` / `LocalFolderExperienceProvider` for shipped content, and `LiveDevExperienceProvider` + `LiveServerBrowser` + `LiveMediaResolver` for Bonjour discovery and concurrent asset prefetch from a Maestro Studio peer on the LAN. `AssetPreloader` warms media before playback.
- **`PulseRingEntity` / `SparkBurstEntity`** — procedural VFX primitives the engine fires via the corresponding step actions.

## Consumer responsibilities

- Provide the visionOS scenes (`@main`, `WindowGroup`, `ImmersiveSpace`) and inject `openImmersiveSpace` / `dismissImmersiveSpace`.
- Register custom action handlers via the `EffectActionExecutor`'s custom-action escape hatch.
- Register product-specific entity factories (USDZs, audio-reactive elements, etc.) on top of the built-in registry.
- Provide a `MediaResolver` for bundled assets (or use `BundleMediaResolver`).

## Installing

`Package.swift`:

```swift
.package(url: "https://github.com/mike-bundy/ChapterPlayer.git", branch: "main")
```

ChapterPlayer tracks the ChapterScript format package at `main` while the wire format is pre-1.0; both will pin to tagged versions once the format settles. A local sibling checkout of `ChapterScript` overrides the remote by package identity (the standard local-override workflow).

## Requirements

- visionOS 26+
- Swift 6.2 / Xcode 26+
- [ChapterScript](https://github.com/mike-bundy/ChapterScript) (resolved automatically)

## Credits

MIT means a visible credit is never required beyond the license notice itself.
That said, if your app ships with ChapterPlayer inside, a mention is
appreciated, and we'd genuinely love to hear what you made:
[hello@chapterscript.com](mailto:hello@chapterscript.com).

## License

MIT — see `LICENSE`.
