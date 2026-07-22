//
//  ChapterPlayerCore.swift
//  ChapterPlayer
//
//  Central observable state for a ChapterPlayer-driven visionOS app.
//  Owns the SegmentEngine, SpatialAudioManager, VideoPlaybackManager,
//  AssetPreloader, and all the pluggable executors. Wires them together
//  and exposes a small surface for the consuming app: `playSegment`,
//  `stopSegment`, `transitionToPhase`, and the live-experience hooks.
//
//  A consuming app typically aliases this type as `AppModel` and observes
//  it via `@Environment(AppModel.self)`. Customize the open/dismiss
//  ImmersiveSpace closures from a SwiftUI `.task` (`Environment(\.open
//  ImmersiveSpace)` / `\.dismissImmersiveSpace` are only available
//  inside a `View`). Optionally pass a non-default `immersiveSpaceID`
//  to the initializer when the consumer's scene declares a different
//  id than the package default.
//

import Foundation
import RealityKit
import SwiftUI
import OSLog
import ChapterScript
import ARKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "ChapterPlayerCore"
)

@MainActor
@Observable
open class ChapterPlayerCore {

    // MARK: - Managers

    public let segmentEngine = SegmentEngine()
    public let audioManager = SpatialAudioManager()
    public let videoManager = VideoPlaybackManager()
    public let assetPreloader = AssetPreloader()

    // MARK: - Executors

    public let entityExecutor = EntityActionExecutor()
    public let audioExecutor: AudioActionExecutor
    public let videoExecutor: VideoActionExecutor
    public let attachmentExecutor = AttachmentActionExecutor()
    public let effectExecutor = EffectActionExecutor()

    // MARK: - Segment routing

    public var activeSegmentId: String?
    public var segmentReentryNonce: Int = 0

    /// The currently-loaded ChapterScript experience document (if any).
    /// Populated by the live-load path (Maestro over Bonjour) or the
    /// consumer's "open project" file-importer flow. Drives segment
    /// lookup for auto-advance and any timeline UI.
    public var loadedExperience: LoadedExperience?

    /// Active hot-reload subscription, when connected to a live
    /// MaestroStudio over Bonjour. Cleared on disconnect.
    public var liveSubscription: LiveSubscription?
    public var liveSubscriptionDescriptor: LiveServerDescriptor?

    /// Set true *before* opening the immersive space when the user
    /// initiated playback via a Live menu. UI affordances watch this so
    /// a fast local-bundle load doesn't clobber the in-flight live fetch.
    public var isLoadingLiveExperience: Bool = false

    /// Descriptor of the live server we're currently *trying* to
    /// connect to. Populated when a live load kicks off and cleared on
    /// success or failure. Drives the loading overlay's
    /// "Connecting to <name>" label.
    public var liveLoadingDescriptor: LiveServerDescriptor?

    /// Last live-load failure surfaced to the user. Cleared on the next
    /// successful load or when the user dismisses the loading overlay.
    public var liveLoadError: String?

    /// Per-asset prefetch progress while the live experience is pulling
    /// files from the Mac. UI binds to this so authors see
    /// "streaming N/M" feedback during initial connect + hot-reloads.
    public let livePrefetchProgress = LivePrefetchProgress()

    /// Turns `loadedExperience.document.entities` into real RealityKit
    /// entities and registers them with `entityExecutor` +
    /// `videoEntityRegistry`. Initialized in `init`.
    public private(set) var documentEntities: DocumentEntityLoader!

    /// Live RealityKit anchor under the immersive root that
    /// `DocumentEntityLoader` parents materialized entities under. Set
    /// by the consumer's `ImmersiveView` after the `RealityView` make
    /// closure runs.
    public var immersiveSceneRoot: Entity? {
        didSet {
            if let document = loadedExperience?.document, immersiveSceneRoot != nil {
                documentEntities.materialize(
                    document: document,
                    sceneRoot: immersiveSceneRoot,
                    mediaResolver: loadedExperience?.mediaResolver
                )
            }
            // Rebase the scene root to the viewer's head so all authored
            // coordinates are implicitly head-relative — entities placed
            // at (x, y, z) in Maestro appear at the same offset from the
            // viewer's head on device. Sampled once when the root mounts;
            // subsequent segment changes don't re-rebase (which would
            // disorientingly shift the world).
            if immersiveSceneRoot != nil {
                Task { await rebaseSceneRootToHead() }
            }
        }
    }

    // MARK: - Head-anchored scene root

    /// One-shot ARKit session that powers head sampling. Lazily started
    /// the first time the immersive scene root mounts; lives for the
    /// app's lifetime so `EntityActionExecutor.headTransformProvider`
    /// stays connected for the (still supported) legacy
    /// `headRelativePosition` action mode.
    private var arkitSession: ARKitSession?
    private var worldTracking: WorldTrackingProvider?

    /// Start head tracking (if not already running), wire the executor's
    /// head provider, then sample once and set the scene root's transform
    /// to match — making world (0,0,0) = the viewer's head.
    private func rebaseSceneRootToHead() async {
        guard let root = immersiveSceneRoot else { return }
        if worldTracking == nil {
            let session = ARKitSession()
            let provider = WorldTrackingProvider()
            do {
                try await session.run([provider])
                self.arkitSession = session
                self.worldTracking = provider
                // Forward to the executor for the legacy head-relative
                // action mode (older documents that still use it).
                self.entityExecutor.headTransformProvider = { [weak provider] in
                    provider?.sampleDeviceTransform(leveled: true)
                }
            } catch {
                logger.warning("ARKit world tracking failed to start: \(error.localizedDescription)")
                return
            }
        }
        guard let provider = worldTracking else {
            logger.warning("World tracking provider not running; scene root left at origin.")
            return
        }
        // `session.run` returning doesn't guarantee an anchor is ready —
        // queryDeviceAnchor frequently returns nil for the first frame
        // or two after start. Poll up to 3s before giving up so the
        // rebase actually fires when the user first enters the
        // immersive space.
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if let head = provider.sampleDeviceTransform(leveled: true) {
                // Take ONLY the head's height (Y) — the viewer's eye
                // level. X / Z / yaw are intentionally NOT taken from
                // the head: an entity authored at (0, 0, -2) should
                // sit 2m in front of the tracking origin regardless
                // of where in the room the viewer is standing or which
                // way they're facing. Otherwise content would slide
                // with the user.
                root.transform = Transform(
                    scale: .one,
                    rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                    translation: SIMD3<Float>(0, head.translation.y, 0)
                )
                logger.info("Rebased scene root to eye height: y=\(head.translation.y) (X/Z/yaw left at tracking origin)")
                return
            }
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
        }
        logger.warning("Head anchor never became available within 3s; scene root left at origin. Check NSWorldSensingUsageDescription in the app's Info.plist.")
    }

    // MARK: - Window / Space IDs

    /// Identifier the consumer's `ImmersiveSpace` scene was declared
    /// with. Passed to the injected `openSpace` closure when a segment's
    /// presentation requires immersion.
    public let immersiveSpaceID: String

    // MARK: - Immersive space lifecycle

    public enum ImmersiveSpaceState: Sendable {
        case closed
        case inTransition
        case open
    }

    public var immersiveSpaceState: ImmersiveSpaceState = .closed
    public var immersionStyle: ImmersionStyle = .full

    /// Kaiser pattern: openSpace / dismissSpace injected from the
    /// consumer app's `.task` where `@Environment(\.openImmersiveSpace)`
    /// / `\.dismissImmersiveSpace` are available. Keeps the core
    /// non-View code.
    public var openSpace: ((String) async -> OpenImmersiveSpaceAction.Result)?
    public var dismissSpace: (() async -> Void)?

    /// Currently-bound USDZ backdrop entity, parented under
    /// `immersiveSceneRoot`. Tracked so `applySegmentBackdrop` can swap
    /// or tear it down when the next segment activates. Nil for video /
    /// image / no-backdrop segments.
    public var currentBackdropUSDZ: Entity?

    /// Whether the skybox entity currently holds a `.image` backdrop's
    /// sphere mesh + UnlitMaterial. Tracked separately from the
    /// VideoPlayerComponent path so segment transitions know which
    /// teardown to run.
    public var currentImageSkyboxActive: Bool = false

    /// Channel name reserved for the segment-level immersive backdrop
    /// video. Independent from any per-step `playVideo` channel so
    /// authors can mix the two without clobbering each other (last
    /// write to the "skybox" entity still wins on visionOS — segment
    /// backdrop runs at segment start; step-level skybox plays can
    /// override it intentionally).
    public static let backdropVideoChannel = "segmentBackdrop"

    /// Name of the ambient backdrop entity in the consumer's
    /// RealityKit scene that should be hidden while a Maestro
    /// experience is loaded. The consumer's `ImmersiveView` typically
    /// names a Reality Composer Pro anchor with this string. Pass
    /// `nil` to disable the hide/restore behavior entirely.
    public let ambientBackdropName: String?

    // MARK: - Init

    public init(
        immersiveSpaceID: String = "ChapterPlayerImmersiveSpace",
        ambientBackdropName: String? = nil
    ) {
        self.immersiveSpaceID = immersiveSpaceID
        self.ambientBackdropName = ambientBackdropName
        self.audioExecutor = AudioActionExecutor(audioManager: audioManager)
        self.videoExecutor = VideoActionExecutor(videoManager: videoManager)
        // The segment backdrop's video channel is owned at the
        // ChapterPlayerCore scope (one backdrop per segment, swapped at
        // segment transitions), not at the segment-engine scope.
        // Protect it from `videoManager.stopAll()` which the engine
        // calls on every segment transition to wipe per-step video
        // state — see `VideoPlaybackManager.protectedChannels`.
        videoManager.protectedChannels.insert(Self.backdropVideoChannel)

        // Wire executors into the engine
        segmentEngine.entityExecutor = entityExecutor
        segmentEngine.audioExecutor = audioExecutor
        segmentEngine.videoExecutor = videoExecutor
        segmentEngine.attachmentExecutor = attachmentExecutor
        segmentEngine.effectExecutor = effectExecutor

        // DocumentEntityLoader needs the two executors it registers
        // entities with. Constructed after self is fully initialized so
        // both executors are wired up.
        self.documentEntities = DocumentEntityLoader(
            entityExecutor: entityExecutor,
            videoManager: videoManager,
            ambientBackdropName: ambientBackdropName
        )

        // Segment lifecycle callbacks
        segmentEngine.onSegmentStarted = { [weak self] segmentId in
            self?.activeSegmentId = segmentId
            self?.segmentReentryNonce += 1
        }

        // Auto-advance: follow CompletionAction.autoAdvance(nextSegmentId:)
        // to the next segment. The next segment must come from the
        // currently-loaded ChapterScript document — the core no longer
        // ships bundled demo segments as a fallback.
        segmentEngine.onSegmentComplete = { [weak self] completion in
            guard let self else { return }
            switch completion {
            case .autoAdvance(let nextId):
                Task { @MainActor in
                    guard let next = self.segmentFromLoadedDocument(id: nextId) else { return }
                    // Respect the next segment's presentation +
                    // backdrop. Auto-advance crosses segment boundaries
                    // so this is exactly where immersive → windowed (or
                    // vice versa) transitions need to fire and where
                    // the previous segment's skybox / USDZ environment
                    // is torn down before the new one binds.
                    await self.applySegmentPresentation(next)
                    self.applySegmentBackdrop(next)
                    _ = await self.segmentEngine.playAndAwait(segment: next)
                }
            case .holdOnLastStep, .transitionTo, .dismissToHome:
                break
            }
        }
    }

    // MARK: - Segment control

    /// Start playback of a named segment. If another segment is already
    /// running it is stopped first. Awaits any required immersive-space
    /// transition (`.immersive` segment wants the space open,
    /// `.windowed` wants it dismissed) before the segment's first step
    /// runs so the engine never fires audio / video against a
    /// mis-presented stage.
    public func playSegment(_ segment: SegmentDefinition) async {
        await applySegmentPresentation(segment)
        applySegmentBackdrop(segment)
        segmentEngine.play(segment: segment)
    }

    /// Bind / swap / tear down the segment's immersive backdrop. Called
    /// from the user-initiated play path and from auto-advance. No-op
    /// for `.windowed` segments (the immersive space isn't open).
    public func applySegmentBackdrop(_ segment: SegmentDefinition) {
        logger.info("[backdrop] applySegmentBackdrop segment=\(segment.id) presentation=\(String(describing: segment.presentation)) backdrop=\(String(describing: segment.immersiveBackdrop))")
        // First, drop whatever was bound for the previous segment so
        // the new segment starts from a clean slate.
        videoManager.stop(channel: Self.backdropVideoChannel)
        currentBackdropUSDZ?.removeFromParent()
        currentBackdropUSDZ = nil
        tearDownImageSkybox()

        // Backdrops only make sense for immersive / mixed segments.
        guard segment.presentation != .windowed,
              let backdrop = segment.immersiveBackdrop
        else {
            logger.info("[backdrop] no backdrop to apply (presentation=\(String(describing: segment.presentation)), spec=\(segment.immersiveBackdrop == nil ? "nil" : "set"))")
            return
        }

        switch backdrop {
        case .video(let file, let layout, let field, let radius, let loop):
            // Video backdrop = stereoscopic-capable VideoPlayerComponent
            // wrapping the camera. Would block the user's mixed-reality
            // view, so reject in mixed mode.
            guard segment.presentation == .immersive else {
                logger.info("Skipping video backdrop on \(String(describing: segment.presentation)) segment — would occlude passthrough.")
                return
            }
            logger.info("[backdrop] dispatching video backdrop file='\(file)' layout=\(String(describing: layout)) field=\(String(describing: field)) radius=\(radius) loop=\(loop)")
            videoManager.play(action: VideoAction(
                file: file,
                channel: Self.backdropVideoChannel,
                volume: 0,
                loop: loop,
                presentation: .immersive(radius: radius, field: field),
                layout: layout
            ))

        case .image(let file, let field, let radius):
            // Static equirectangular image skybox. Same occlusion
            // concern as video — sphere wraps the user — so reject in
            // mixed mode.
            guard segment.presentation == .immersive else {
                logger.info("Skipping image backdrop on \(String(describing: segment.presentation)) segment — would occlude passthrough.")
                return
            }
            bindImageSkybox(file: file, field: field, radius: radius, segmentId: segment.id)

        case .usdz(let assetId):
            // USDZ backdrops work in BOTH immersive and mixed modes —
            // a 3D set piece floating in space is fine over
            // passthrough.
            guard let sceneRoot = immersiveSceneRoot,
                  let url = resolveBackdropAssetURL(file: assetId, kind: .usdz)
            else {
                logger.warning("Backdrop USDZ '\(assetId)' could not be located on disk.")
                return
            }
            Task { @MainActor in
                do {
                    let entity = try await Entity(contentsOf: url)
                    guard self.activeSegmentId == segment.id else { return }
                    sceneRoot.addChild(entity)
                    self.currentBackdropUSDZ = entity
                } catch {
                    logger.warning("Failed to load backdrop USDZ '\(assetId)': \(String(describing: error))")
                }
            }
        }
    }

    /// Build a sphere mesh + UnlitMaterial(texture:) on the skybox
    /// entity using the file as an equirectangular projection. Half-
    /// sphere for `.equirect180`, full sphere for `.equirect360`.
    private func bindImageSkybox(file: String, field: ImmersiveField, radius: Float, segmentId: String) {
        guard let url = resolveBackdropAssetURL(file: file, kind: .image) else {
            logger.warning("Backdrop image '\(file)' could not be located on disk.")
            return
        }
        guard let skybox = videoManager.videoEntityRegistry["skybox"] else {
            logger.warning("Image backdrop has no 'skybox' entity registered.")
            return
        }
        Task { @MainActor in
            do {
                let texture = try await TextureResource(contentsOf: url, options: .init(semantic: .color))
                guard self.activeSegmentId == segmentId else { return }
                let mesh: MeshResource
                switch field {
                case .equirect360:
                    mesh = MeshResource.generateSphere(radius: radius)
                case .equirect180:
                    // Half-sphere — approximate via a full sphere;
                    // visionOS doesn't ship a hemisphere generator.
                    // For most VR180 matte paintings this still looks
                    // correct because the texture's "back half" maps
                    // to a duplicate of the front when the image is
                    // encoded that way. For true 180° images, scale
                    // the texture differently in materials.
                    mesh = MeshResource.generateSphere(radius: radius)
                }
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                let model = ModelComponent(mesh: mesh, materials: [material])
                skybox.components.set(model)
                // Inside-out so the user sees the texture from inside.
                skybox.scale = SIMD3<Float>(-1, 1, 1)
                skybox.isEnabled = true
                self.currentImageSkyboxActive = true
            } catch {
                logger.warning("Failed to load backdrop image '\(file)': \(String(describing: error))")
            }
        }
    }

    /// Reverse `bindImageSkybox` — drop the ModelComponent so the
    /// skybox entity returns to its empty-anchor state for the next
    /// segment's binding. Idempotent (no-op when no image was bound).
    private func tearDownImageSkybox() {
        guard currentImageSkyboxActive,
              let skybox = videoManager.videoEntityRegistry["skybox"]
        else { return }
        skybox.components.remove(ModelComponent.self)
        skybox.scale = .one
        skybox.isEnabled = false
        currentImageSkyboxActive = false
    }

    /// Resolve an asset id to a file URL. Consults the loaded
    /// experience's media resolver first (so live / packaged
    /// experiences shadow the app bundle), then falls back to the main
    /// bundle.
    private func resolveBackdropAssetURL(file: String, kind: MediaKind) -> URL? {
        if let resolved = loadedExperience?.mediaResolver.url(for: file, kind: kind) {
            return resolved
        }
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: stem.isEmpty ? file : stem, withExtension: ext.isEmpty ? "usdz" : ext)
    }

    /// Open or dismiss the ImmersiveSpace to match the segment's
    /// `presentation`. Updates `immersionStyle` so the active style
    /// (full vs mixed) tracks the segment even when the space is
    /// already open. Toggles the always-loaded ambient background
    /// entities so they don't occlude passthrough in mixed-mode
    /// segments.
    public func applySegmentPresentation(_ segment: SegmentDefinition) async {
        logger.info("[presentation] applySegmentPresentation segment=\(segment.id) presentation=\(String(describing: segment.presentation)) spaceState=\(String(describing: self.immersiveSpaceState))")
        switch segment.presentation {
        case .immersive, .mixed:
            let desiredStyle: ImmersionStyle = segment.presentation == .immersive ? .full : .mixed
            applyAmbientBackgroundVisibility(for: segment)
            if immersiveSpaceState == .open {
                immersionStyle = desiredStyle
                return
            }
            guard let openSpace else { return }
            immersionStyle = desiredStyle
            immersiveSpaceState = .inTransition
            switch await openSpace(immersiveSpaceID) {
            case .opened:
                immersiveSpaceState = .open
            case .userCancelled, .error:
                immersiveSpaceState = .closed
            @unknown default:
                immersiveSpaceState = .closed
            }
        case .windowed:
            guard immersiveSpaceState != .closed, let dismissSpace else { return }
            immersiveSpaceState = .inTransition
            await dismissSpace()
            immersiveSpaceState = .closed
        }
    }

    /// Show or hide the always-loaded ambient background entities
    /// based on the segment's presentation + backdrop. The
    /// `ambientBackdropName` set at init controls which scene-tree
    /// entity (e.g. a Reality Composer Pro anchor) is toggled
    /// alongside the skybox.
    private func applyAmbientBackgroundVisibility(for segment: SegmentDefinition) {
        let rcpBackdrop: Entity? = {
            guard let name = ambientBackdropName else { return nil }
            return immersiveSceneRoot?.findEntity(named: name)
        }()
        let skybox = immersiveSceneRoot?.findEntity(named: "skybox")
            ?? videoManager.videoEntityRegistry["skybox"]
        switch segment.presentation {
        case .immersive:
            switch segment.immersiveBackdrop {
            case .none:
                rcpBackdrop?.isEnabled = true
                skybox?.isEnabled = false
            case .video?, .image?:
                rcpBackdrop?.isEnabled = false
                skybox?.isEnabled = true
            case .usdz?:
                rcpBackdrop?.isEnabled = false
                skybox?.isEnabled = false
            }
        case .mixed:
            rcpBackdrop?.isEnabled = false
            skybox?.isEnabled = false
        case .windowed:
            break
        }
    }

    public func stopSegment(fullReset: Bool = false) {
        segmentEngine.stop(resetEntities: true, fullReset: fullReset)
        activeSegmentId = nil
    }

    /// Look up `id` in the currently-loaded ChapterScript document,
    /// converting the matching DTO into a runtime `SegmentDefinition`.
    /// Returns nil if no document is loaded or the id isn't present.
    public func segmentFromLoadedDocument(id: String) -> SegmentDefinition? {
        guard let document = loadedExperience?.document else { return nil }
        return try? SegmentDefinition.from(document: document, segmentId: id)
    }

    /// All runtime segments that the player UI should render in any
    /// timeline scrub bar. When a ChapterScript document is loaded
    /// (live, file-open, or local folder), returns its segments mapped
    /// through `SegmentDefinition.from`. Empty when nothing is loaded
    /// — the consumer's UI surfaces an empty state.
    public var displaySegments: [SegmentDefinition] {
        guard let document = loadedExperience?.document else { return [] }
        return document.segments.compactMap { dto in
            try? SegmentDefinition.from(document: document, segmentId: dto.id)
        }
    }

    // MARK: - Phase transitions

    /// Minimal phase router. `"immersive"` opens the ImmersiveSpace and
    /// auto-plays the default segment. `"idle"` stops playback and
    /// dismisses the space.
    public func transitionToPhase(_ phase: String) async {
        switch phase {
        case "immersive":
            guard immersiveSpaceState == .closed else {
                logger.info("transitionToPhase(immersive) skipped — state=\(String(describing: self.immersiveSpaceState))")
                return
            }
            guard let openSpace else {
                logger.error("transitionToPhase(immersive): openSpace closure not injected")
                return
            }
            immersiveSpaceState = .inTransition
            let result = await openSpace(immersiveSpaceID)
            switch result {
            case .opened:
                immersiveSpaceState = .open
                logger.info("Immersive space opened")
            case .userCancelled, .error:
                immersiveSpaceState = .closed
                logger.warning("Immersive space open failed: \(String(describing: result))")
            @unknown default:
                immersiveSpaceState = .closed
            }

        case "idle":
            stopSegment(fullReset: true)
            if let dismissSpace, immersiveSpaceState != .closed {
                immersiveSpaceState = .inTransition
                await dismissSpace()
                immersiveSpaceState = .closed
                logger.info("Immersive space dismissed")
            }

        default:
            logger.warning("Unknown phase: \(phase)")
        }
    }
}
