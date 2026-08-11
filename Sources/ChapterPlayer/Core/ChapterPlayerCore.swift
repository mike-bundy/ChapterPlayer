//
//  ChapterPlayerCore.swift
//  ChapterPlayer
//
//  Central observable state for a ChapterPlayer-driven visionOS app.
//  Owns the SequenceEngine, SpatialAudioManager, VideoPlaybackManager,
//  AssetPreloader, and all the pluggable executors. Wires them together
//  and exposes a small surface for the consuming app: `playSequence`,
//  `stopSequence`, `transitionToPhase`, and the live-experience hooks.
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
import CoreMedia

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "ChapterPlayerCore"
)

@MainActor private var _lastVideoBackdropSignatureStore: String?

@MainActor
@Observable
open class ChapterPlayerCore {

    // MARK: - Managers

    public let sequenceEngine = SequenceEngine()
    public let audioManager = SpatialAudioManager()
    public let videoManager = VideoPlaybackManager()
    public let assetPreloader = AssetPreloader()

    // MARK: - Executors

    public let entityExecutor = EntityActionExecutor()
    public let audioExecutor: AudioActionExecutor
    public let videoExecutor: VideoActionExecutor
    public let attachmentExecutor = AttachmentActionExecutor()
    public let effectExecutor = EffectActionExecutor()

    /// Runtime detection for the spatial gate types (gaze / proximity /
    /// grab). Tap/orchestrator gates stay consumer-wired to `satisfyGate()`.
    public let gateDetection = GateDetectionController()
    /// Follows the active sequence's timed backdrop track. Lazy because it
    /// needs `self` as its presenter, and observation-ignored because it is a
    /// driver, not rendered state — tracking it would invalidate every view
    /// on each cue swap.
    @ObservationIgnored
    public private(set) lazy var backdropCues = BackdropCueDriver(presenter: self)

    // MARK: - Sequence routing

    public var activeSequenceId: String?
    public var sequenceReentryNonce: Int = 0

    /// The currently-loaded ChapterScript experience document (if any).
    /// Populated by the live-load path (Maestro over Bonjour) or the
    /// consumer's "open project" file-importer flow. Drives sequence
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
            // subsequent sequence changes don't re-rebase (which would
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
    /// Last eye height a plausibility-checked sample produced. The rebase
    /// falls back to it when a fresh mount's poll window expires without
    /// a believable pose.
    private var lastKnownEyeHeight: Float?

    /// Start head tracking, wire the executor's head provider, then sample
    /// once and set the scene root's transform to match — making world
    /// (0,0,0) = the viewer's head.
    ///
    /// A FRESH session runs on every mount: ARKit suspends providers when
    /// the immersive space closes and re-establishes the world origin when
    /// a new one opens — a provider kept from the previous space can
    /// return confidently-TRACKED poses in the stale coordinate frame
    /// (head at y≈0.1 "eye height", content on the floor). Session-per-
    /// mount keeps every sample in the current space's frame.
    private func rebaseSceneRootToHead() async {
        guard let root = immersiveSceneRoot else { return }
        let session = ARKitSession()
        let provider = WorldTrackingProvider()
        do {
            try await session.run([provider])
            self.arkitSession?.stop()
            self.arkitSession = session
            self.worldTracking = provider
            // Forward to the executor for the legacy head-relative
            // action mode (older documents that still use it).
            self.entityExecutor.headTransformProvider = { [weak provider] in
                provider?.sampleDeviceTransform(leveled: true)
            }
            // Spatial gates need the FULL head orientation — gaze aim
            // uses pitch, which the leveled sample above strips.
            self.gateDetection.headTransformProvider = { [weak provider] in
                provider?.sampleDeviceTransform(leveled: false)
            }
        } catch {
            logger.warning("ARKit world tracking failed to start: \(error.localizedDescription)")
            return
        }
        // `session.run` returning doesn't guarantee an anchor is ready —
        // queryDeviceAnchor frequently returns nil (or, mid-relocalization,
        // an implausible pose) for the first frames. Poll, and only accept
        // a height a human head can actually be at: 0.5–2.5 m. y≈0.1 is
        // never an eye — it's an origin that hasn't settled.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if let head = provider.sampleDeviceTransform(leveled: true),
               (0.5...2.5).contains(head.translation.y) {
                // Take ONLY the head's height (Y) — the viewer's eye
                // level. X / Z / yaw are intentionally NOT taken from
                // the head: an entity authored at (0, 0, -2) should
                // sit 2m in front of the tracking origin regardless
                // of where in the room the viewer is standing or which
                // way they're facing. Otherwise content would slide
                // with the user.
                lastKnownEyeHeight = head.translation.y
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
        if let fallback = lastKnownEyeHeight {
            root.transform = Transform(
                scale: .one,
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                translation: SIMD3<Float>(0, fallback, 0)
            )
            logger.warning("No plausible head pose within 4s; reusing last known eye height y=\(fallback).")
        } else {
            logger.warning("Head anchor never became available within 4s; scene root left at origin. Check NSWorldSensingUsageDescription in the app's Info.plist.")
        }
    }

    // MARK: - Window / Space IDs

    /// Identifier the consumer's `ImmersiveSpace` scene was declared
    /// with. Passed to the injected `openSpace` closure when a sequence's
    /// presentation requires immersion.
    public let immersiveSpaceID: String

    // MARK: - Immersive space lifecycle

    public enum ImmersiveSpaceState: Sendable {
        case closed
        case inTransition
        case open
    }

    public var immersiveSpaceState: ImmersiveSpaceState = .closed
    public var immersionStyle: ImmersionStyle = .full {
        didSet { immersionRevision &+= 1 }
    }
    /// Equatable pulse for `immersionStyle` (which isn't Equatable).
    /// Scene bodies do NOT track @Observable reads, so a computed Binding
    /// inside `.immersionStyle(selection:)` never re-evaluates when the
    /// model changes the style mid-session (sequence presentation
    /// switches while the space is open silently no-op). Apps must keep
    /// the selection in scene @State and sync it from a VIEW via
    /// `.onChange(of: core.immersionRevision)`.
    public private(set) var immersionRevision: Int = 0

    /// Kaiser pattern: openSpace / dismissSpace injected from the
    /// consumer app's `.task` where `@Environment(\.openImmersiveSpace)`
    /// / `\.dismissImmersiveSpace` are available. Keeps the core
    /// non-View code.
    public var openSpace: ((String) async -> OpenImmersiveSpaceAction.Result)?
    public var dismissSpace: (() async -> Void)?

    /// Currently-bound USDZ backdrop entity, parented under
    /// `immersiveSceneRoot`. Tracked so `applySequenceBackdrop` can swap
    /// or tear it down when the next sequence activates. Nil for video /
    /// image / no-backdrop sequences.
    public var currentBackdropUSDZ: Entity?

    /// Whether the skybox entity currently holds a `.image` backdrop's
    /// sphere mesh + UnlitMaterial. Tracked separately from the
    /// VideoPlayerComponent path so sequence transitions know which
    /// teardown to run.
    public var currentImageSkyboxActive: Bool = false

    /// Channel name reserved for the sequence-level immersive backdrop
    /// video. Independent from any per-step `playVideo` channel so
    /// authors can mix the two without clobbering each other (last
    /// write to the "skybox" entity still wins on visionOS — sequence
    /// backdrop runs at sequence start; step-level skybox plays can
    /// override it intentionally).
    public static let backdropVideoChannel = "sequenceBackdrop"

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
        // The sequence backdrop's video channel is owned at the
        // ChapterPlayerCore scope (one backdrop per sequence, swapped at
        // sequence transitions), not at the sequence-engine scope.
        // Protect it from `videoManager.stopAll()` which the engine
        // calls on every sequence transition to wipe per-step video
        // state — see `VideoPlaybackManager.protectedChannels`.
        videoManager.protectedChannels.insert(Self.backdropVideoChannel)

        // Wire executors into the engine
        sequenceEngine.entityExecutor = entityExecutor
        sequenceEngine.audioExecutor = audioExecutor
        sequenceEngine.videoExecutor = videoExecutor
        sequenceEngine.attachmentExecutor = attachmentExecutor
        sequenceEngine.effectExecutor = effectExecutor

        // Spatial gate detection: resolve gate targets out of the entity
        // registry; the head provider is wired when world tracking starts
        // (`rebaseSceneRootToHead`).
        sequenceEngine.gateDetector = gateDetection
        sequenceEngine.backdropDriver = backdropCues
        gateDetection.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }

        // DocumentEntityLoader needs the two executors it registers
        // entities with. Constructed after self is fully initialized so
        // both executors are wired up.
        self.documentEntities = DocumentEntityLoader(
            entityExecutor: entityExecutor,
            videoManager: videoManager,
            ambientBackdropName: ambientBackdropName
        )

        // Sequence lifecycle callbacks
        sequenceEngine.onSequenceStarted = { [weak self] sequenceId in
            self?.activeSequenceId = sequenceId
            self?.sequenceReentryNonce += 1
        }

        // Auto-advance: follow CompletionAction.autoAdvance(nextSequenceId:)
        // to the next sequence. The next sequence must come from the
        // currently-loaded ChapterScript document — the core no longer
        // ships bundled demo sequences as a fallback.
        sequenceEngine.onSequenceComplete = { [weak self] completion in
            guard let self else { return }
            switch completion {
            case .autoAdvance(let nextId):
                Task { @MainActor in
                    // Follow the WHOLE chain here: `playAndAwait` returns
                    // the next sequence's completion action instead of
                    // re-firing this callback, so seg1 → seg2 → seg3 only
                    // works if this loop keeps walking.
                    var targetId = nextId
                    while true {
                        guard let next = self.sequenceFromLoadedDocument(id: targetId) else {
                            logger.info("[auto-advance] target sequence '\(targetId)' not found in loaded document — stopping")
                            break
                        }
                        // Respect the next sequence's presentation +
                        // backdrop. Auto-advance crosses sequence boundaries
                        // so this is exactly where immersive → windowed (or
                        // vice versa) transitions need to fire and where
                        // the previous sequence's skybox / USDZ environment
                        // is torn down before the new one binds.
                        await self.applySequencePresentation(next)
                        self.applySequenceBackdrop(next)
                        let chained = await self.sequenceEngine.playAndAwait(sequence: next)
                        guard case .autoAdvance(let chainedId) = chained else { break }
                        targetId = chainedId
                    }
                }
            case .holdOnLastStep, .transitionTo, .dismissToHome:
                break
            }
        }
    }

    // MARK: - Sequence control

    /// Start playback of a named sequence. If another sequence is already
    /// running it is stopped first. Awaits any required immersive-space
    /// transition (`.immersive` sequence wants the space open,
    /// `.windowed` wants it dismissed) before the sequence's first step
    /// runs so the engine never fires audio / video against a
    /// mis-presented stage.
    public func playSequence(_ sequence: SequenceDefinition) async {
        await applySequencePresentation(sequence)
        // The FIRST play of a session races the ImmersiveSpace open:
        // openSpace returns when the system creates the scene, but the
        // consumer's RealityView registers the skybox shell a beat later
        // — and a backdrop dispatched into an empty registry gives up
        // ("skybox NOT registered" → black surround until the next play).
        // Wait briefly for registration before binding the backdrop.
        if sequence.presentation == .immersive, sequence.immersiveBackdrop != nil,
           videoManager.videoEntityRegistry["skybox"] == nil {
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline, videoManager.videoEntityRegistry["skybox"] == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            logger.info("[backdrop] skybox registration wait finished (registered=\(self.videoManager.videoEntityRegistry["skybox"] != nil))")
        }
        applySequenceBackdrop(sequence)
        sequenceEngine.play(sequence: sequence)
    }

    /// Bind / swap / tear down the sequence's immersive backdrop. Called
    /// from the user-initiated play path and from auto-advance. No-op
    /// for `.windowed` sequences (the immersive space isn't open).
    /// Signature of the video backdrop currently bound (nil = none).
    /// Drives the replay fast path below.
    private static var lastVideoBackdropSignature: String? {
        get { _lastVideoBackdropSignatureStore }
        set { _lastVideoBackdropSignatureStore = newValue }
    }

    /// Apply the backdrop showing at the START of `sequence`.
    ///
    /// Cue zero, not "the sequence's backdrop" — with a track authored, the
    /// sequence does not have ONE backdrop, and `BackdropCueDriver` takes over
    /// from here to follow the rest. Kept as the entry point the play path
    /// already calls so the pre-track behaviour is unchanged for documents
    /// with no cues.
    public func applySequenceBackdrop(_ sequence: SequenceDefinition) {
        let cue = SequenceBackdropTimeline.activeCue(
            at: 0,
            track: sequence.backdropTrack,
            legacy: sequence.immersiveBackdrop.map { ImmersiveBackdropSpec(runtime: $0) }
        )
        presentBackdrop(cue?.spec.flatMap { SequenceBackdrop($0) },
                        sourceRange: cue?.sourceRange ?? .full,
                        presentation: sequence.presentation,
                        sequenceId: sequence.id)
    }

    public func presentBackdrop(
        _ spec: SequenceBackdrop?,
        sourceRange: MediaSourceRange,
        presentation: SequencePresentation
    ) {
        presentBackdrop(spec, sourceRange: sourceRange,
                        presentation: presentation, sequenceId: activeSequenceId ?? "")
    }

    /// Fade whatever backdrop is mounted. Both slots are written because either
    /// may be live — a video/image skybox and a USDZ backdrop mount to different
    /// entities, and the driver does not know (or want to know) which.
    ///
    /// `OpacityComponent` is the same mechanism `VideoPlaybackManager` uses to
    /// hold a cold video at zero until it is ready, so a backdrop fade costs no
    /// new machinery and behaves identically on device.
    public func setBackdropOpacity(_ opacity: Float) {
        let clamped = max(0, min(1, opacity))
        for entity in [videoManager.videoEntityRegistry["skybox"], currentBackdropUSDZ] {
            guard let entity else { continue }
            entity.components.set(OpacityComponent(opacity: clamped))
        }
    }

    private func presentBackdrop(
        _ backdropSpec: SequenceBackdrop?,
        sourceRange: MediaSourceRange,
        presentation sequencePresentation: SequencePresentation,
        sequenceId: String
    ) {
        logger.info("[backdrop] present sequence=\(sequenceId) presentation=\(String(describing: sequencePresentation)) backdrop=\(String(describing: backdropSpec))")
        // REPLAY FAST PATH — the single most important rule this pipeline
        // has learned on device: re-attaching a VideoPlayerComponent after
        // a stop strips it is FLAKY (same logs, sometimes renders,
        // sometimes ready-but-black). A replay of the IDENTICAL video
        // backdrop therefore never touches the component: verify the
        // live binding (same config, live player + item, skybox mounted
        // in a scene and still hosting its component) and just seek to
        // the start and play. Any mismatch or dead binding falls through
        // to the normal teardown + rebuild.
        if case .video(let file, let layout, let field, let radius, let loop, let audioEnabled)? = backdropSpec,
           sequencePresentation == .immersive,
           currentBackdropUSDZ == nil {
            // The source window is part of the signature: the same file cut
            // 0-6 and cut 20-26 are two different backdrops, and treating
            // them as identical would replay the first window for the second
            // cue.
            let signature = "\(file)|\(layout)|\(field)|\(radius)|\(loop)|\(audioEnabled)|\(sourceRange.resolvedIn)|\(String(describing: sourceRange.sourceOut))"
            if signature == Self.lastVideoBackdropSignature,
               let player = videoManager.player(for: Self.backdropVideoChannel),
               let item = player.currentItem, item.status != .failed,
               let skybox = videoManager.videoEntityRegistry["skybox"],
               skybox.scene != nil,
               skybox.components.has(VideoPlayerComponent.self) {
                skybox.isEnabled = true
                // Back to the WINDOW's start, not the file's.
                player.seek(to: CMTime(seconds: sourceRange.resolvedIn, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                logger.info("[backdrop] REPLAY fast path: identical backdrop, live binding verified — seek+play, component untouched")
                return
            }
        }
        // First, drop whatever was bound for the previous sequence so
        // the new sequence starts from a clean slate.
        videoManager.stop(channel: Self.backdropVideoChannel)
        currentBackdropUSDZ?.removeFromParent()
        currentBackdropUSDZ = nil
        tearDownImageSkybox()

        // Backdrops only make sense for immersive / mixed sequences.
        Self.lastVideoBackdropSignature = nil
        guard sequencePresentation != .windowed, let backdrop = backdropSpec else {
            logger.info("[backdrop] nothing to apply (presentation=\(String(describing: sequencePresentation)), spec=\(backdropSpec == nil ? "nil" : "set"))")
            return
        }

        switch backdrop {
        case .video(let file, let layout, let field, let radius, let loop, let audioEnabled):
            // Video backdrop = stereoscopic-capable VideoPlayerComponent
            // wrapping the camera. Would block the user's mixed-reality
            // view, so reject in mixed mode.
            guard sequencePresentation == .immersive else {
                logger.info("Skipping video backdrop on \(String(describing: sequencePresentation)) sequence — would occlude passthrough.")
                return
            }
            logger.info("[backdrop] dispatching video backdrop file='\(file)' layout=\(String(describing: layout)) field=\(String(describing: field)) radius=\(radius) loop=\(loop) audio=\(audioEnabled)")
            Self.lastVideoBackdropSignature = "\(file)|\(layout)|\(field)|\(radius)|\(loop)|\(audioEnabled)|\(sourceRange.resolvedIn)|\(String(describing: sourceRange.sourceOut))"
            videoManager.play(action: VideoAction(
                file: file,
                channel: Self.backdropVideoChannel,
                volume: audioEnabled ? 1 : 0,
                loop: loop,
                presentation: .immersive(radius: radius, field: field),
                layout: layout,
                sourceIn: sourceRange.sourceIn,
                sourceOut: sourceRange.sourceOut
            ))

        case .image(let file, let field, let radius):
            // Static equirectangular image skybox. Same occlusion
            // concern as video — sphere wraps the user — so reject in
            // mixed mode.
            guard sequencePresentation == .immersive else {
                logger.info("Skipping image backdrop on \(String(describing: sequencePresentation)) sequence — would occlude passthrough.")
                return
            }
            bindImageSkybox(file: file, field: field, radius: radius, sequenceId: sequenceId)

        case .usdz(let assetId):
            // USDZ backdrops work in BOTH immersive and mixed modes —
            // a 3D set piece floating in space is fine over
            // passthrough.
            guard let sceneRoot = immersiveSceneRoot else {
                logger.warning("Backdrop USDZ '\(assetId)' skipped — immersive scene root not mounted.")
                return
            }
            guard let url = resolveBackdropAssetURL(file: assetId, kind: .usdz) else {
                logger.warning("Backdrop USDZ '\(assetId)' could not be located on disk.")
                return
            }
            Task { @MainActor in
                do {
                    let entity = try await Entity(contentsOf: url)
                    guard self.activeSequenceId == sequenceId else { return }
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
    private func bindImageSkybox(file: String, field: ImmersiveField, radius: Float, sequenceId: String) {
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
                guard self.activeSequenceId == sequenceId else { return }
                let mesh: MeshResource
                switch field {
                case .equirect360:
                    mesh = MeshResource.generateSphere(radius: radius)
                case .equirect180, .appleImmersive, .custom:
                    // Partial shell — still approximated by a full sphere;
                    // visionOS doesn't ship a hemisphere generator.
                    // For most VR180 matte paintings this still looks
                    // correct because the texture's "back half" maps
                    // to a duplicate of the front when the image is
                    // encoded that way. For true 180° images, scale
                    // the texture differently in materials.
                    //
                    // KNOWN GAP: this is now wrong for Apple Immersive and
                    // custom fields in a way it was only arguably wrong for
                    // 180° — their sweep is neither π nor 2π, so no
                    // full-sphere mapping approximates them. The correct fix
                    // is to build the shell from `field.horizontalDegrees`,
                    // the way the Mac's `BackdropMesh` does via
                    // `MaestroKit.BackdropGeometry`. Tracked in STATUS.
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
    /// sequence's binding. Idempotent (no-op when no image was bound).
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
    /// bundle. `open` so live editors with a local-first resolver
    /// (MaestroVision — in-session imports exist only in its device
    /// cache, invisible to the frozen load-time resolver) can route
    /// backdrop lookups the same way as every other asset path.
    open func resolveBackdropAssetURL(file: String, kind: MediaKind) -> URL? {
        if let resolved = loadedExperience?.mediaResolver.url(for: file, kind: kind) {
            return resolved
        }
        let stem = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: stem.isEmpty ? file : stem, withExtension: ext.isEmpty ? "usdz" : ext)
    }

    /// Open or dismiss the ImmersiveSpace to match the sequence's
    /// `presentation`. Updates `immersionStyle` so the active style
    /// (full vs mixed) tracks the sequence even when the space is
    /// already open. Toggles the always-loaded ambient background
    /// entities so they don't occlude passthrough in mixed-mode
    /// sequences.
    public func applySequencePresentation(_ sequence: SequenceDefinition) async {
        logger.info("[presentation] applySequencePresentation sequence=\(sequence.id) presentation=\(String(describing: sequence.presentation)) spaceState=\(String(describing: self.immersiveSpaceState))")
        switch sequence.presentation {
        case .immersive, .mixed:
            let desiredStyle: ImmersionStyle = sequence.presentation == .immersive ? .full : .mixed
            applyAmbientBackgroundVisibility(for: sequence)
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
    /// based on the sequence's presentation + backdrop. The
    /// `ambientBackdropName` set at init controls which scene-tree
    /// entity (e.g. a Reality Composer Pro anchor) is toggled
    /// alongside the skybox.
    private func applyAmbientBackgroundVisibility(for sequence: SequenceDefinition) {
        let rcpBackdrop: Entity? = {
            guard let name = ambientBackdropName else { return nil }
            return immersiveSceneRoot?.findEntity(named: name)
        }()
        let skybox = immersiveSceneRoot?.findEntity(named: "skybox")
            ?? videoManager.videoEntityRegistry["skybox"]
        switch sequence.presentation {
        case .immersive:
            switch sequence.immersiveBackdrop {
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

    public func stopSequence(fullReset: Bool = false) {
        sequenceEngine.stop(resetEntities: true, fullReset: fullReset)
        // The backdrop video channel is PROTECTED from stopAll() so its
        // VideoPlayerComponent survives sequence-to-sequence rebinds
        // (re-attaching the component after a strip is flaky on device).
        // Protection must not mean the transport can't silence it: PAUSE
        // the player — picture freezes, audio stops, the component stays
        // attached, and the replay fast path resumes it on the next play.
        videoManager.player(for: Self.backdropVideoChannel)?.pause()
        activeSequenceId = nil
    }

    /// Look up `id` in the currently-loaded ChapterScript document,
    /// converting the matching DTO into a runtime `SequenceDefinition`.
    /// Returns nil if no document is loaded or the id isn't present.
    /// `open` so live editors whose working document diverges from the
    /// load-time snapshot (MaestroVision) can resolve auto-advance
    /// targets against their CURRENT document instead.
    open func sequenceFromLoadedDocument(id: String) -> SequenceDefinition? {
        guard let document = loadedExperience?.document else { return nil }
        return try? SequenceDefinition.from(document: document, sequenceId: id)
    }

    /// All runtime sequences that the player UI should render in any
    /// timeline scrub bar. When a ChapterScript document is loaded
    /// (live, file-open, or local folder), returns its sequences mapped
    /// through `SequenceDefinition.from`. Empty when nothing is loaded
    /// — the consumer's UI surfaces an empty state.
    public var displaySequences: [SequenceDefinition] {
        guard let document = loadedExperience?.document else { return [] }
        return document.sequences.compactMap { dto in
            try? SequenceDefinition.from(document: document, sequenceId: dto.id)
        }
    }

    // MARK: - Phase transitions

    /// Minimal phase router. `"immersive"` opens the ImmersiveSpace and
    /// auto-plays the default sequence. `"idle"` stops playback and
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
            stopSequence(fullReset: true)
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
