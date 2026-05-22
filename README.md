# ChapterPlayer

Swift package that runs ChapterScript documents on visionOS. Bundles the chapter engine, spatial audio + immersive video managers, entity factory, and live-experience client into a single framework so a consuming app only needs to ship its UI, content, and product-specific extensions.

## What's in the package

- **`ChapterEngine`** — declarative chapter/step choreographer. Always resets entities on chapter change; pluggable executor protocols for entity / audio / video / attachment / effect actions.
- **`SpatialAudioManager`** — `AVAudioEngine` + `PHASEEngine` ambient/spatial channel system with category mixing, ducking, audio zones, loop configs.
- **`VideoPlaybackManager`** — per-channel `AVPlayer` orchestrator. Supports flat panels via `VideoMaterial`, attachment-based SwiftUI overlays, and 360°/180° immersive skybox via `VideoPlayerComponent` (matches Apple's `PlayingImmersiveMediaWithRealityKit` sample).
- **`EntityFactory`** — builds RealityKit entities for ChapterScript `EntityDefinition`s (primitives, USDZs, text, lights, video panels).
- **`DocumentEntityLoader`** — materializes the document's entities into the immersive scene, registers them with the executors and video-entity registry.
- **`LiveDevExperienceProvider` + `LiveMediaResolver`** — Bonjour discovery + concurrent delegate-based prefetch of asset bundles from a Maestro Studio peer on the LAN.
- **`PulseRingEntity` / `SparkBurstEntity`** — VFX primitives the engine fires via `StepAction.showPulseRing` / `.startSparkBurst`.

## Consumer responsibilities

- Provide the visionOS scenes (`@main`, `WindowGroup`, `ImmersiveSpace`) and inject `openImmersiveSpace`/`dismissImmersiveSpace` into the player core.
- Register custom action handlers via the `EffectActionExecutor`'s custom-action escape hatch.
- Register product-specific entity factories (USDZs, audio reactive elements, etc.) on top of the built-in registry.
- Provide a `MediaResolver` for bundled assets (or use `BundleMediaResolver`).

## Requirements

- visionOS 26.2
- Swift 6.0 / Xcode 26+
- ChapterScript 0.4.0+
