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

    /// ONE sensing layer for "look at it", "walk up to it" and "grab it".
    /// Shared by gates and entity interactions — two detectors polling the same
    /// head pose would be two answers to one question, and twice the device QA.
    public let spatialTriggers = SpatialTriggerDetector()

    /// Runtime detection for the spatial gate types (viewer-facing / proximity
    /// / grab). Tap/orchestrator gates stay consumer-wired to `satisfyGate()`.
    public let gateDetection: GateDetectionController

    /// Live entity interactions: registration, lifetime, response dispatch and
    /// the accessible hover affordance. See `InteractionController`.
    public let interactions: InteractionController

    /// EXPLORE regions: the two clocks, the fallback timer and the
    /// continuation behaviours. See `StoryRegionController`.
    public let storyRegions = StoryRegionController()

    /// THE ONE AUTHORITY FOR MOVEMENT BETWEEN SEQUENCES.
    ///
    /// Completion, Interaction responses and host commands all emit a
    /// `NavigationRequest`; this decides, and `perform(_:)` carries it out.
    /// Nothing else may start a Sequence — two things that both can is how a
    /// chapter ends up playing two at once.
    @ObservationIgnored public var navigator = ExperienceNavigator()

    /// WHAT THE CHAPTER REMEMBERS, for this playback session.
    ///
    /// Owned here because a Chapter playback session is a property of the whole
    /// run, not of a Sequence — the engine, the gate wait and the navigator all
    /// read this one store. Never serialized; see `StoryStateStore`.
    public let storyState = StoryStateStore()
    /// Follows the active sequence's timed backdrop track. Lazy because it
    /// needs `self` as its presenter, and observation-ignored because it is a
    /// driver, not rendered state — tracking it would invalidate every view
    /// on each cue swap.
    @ObservationIgnored
    public private(set) lazy var backdropCues = BackdropCueDriver(presenter: self)

    // MARK: - Sequence routing

    public var activeSequenceId: String?
    /// The visit currently executing, so an entry can tell a fresh one from a
    /// resumed one. Runtime state: never serialized, cleared when the run ends.
    private var activeVisitID: SequenceVisitID?
    /// One suspended visit's interaction state per visit id. Bounded for the
    /// same reason the navigator bounds its history: an hour of navigating must
    /// not accumulate without limit.
    private var visitLedgers: [SequenceVisitID: InteractionLedger] = [:]

    private func pruneVisitLedgers() {
        guard visitLedgers.count > 64 else { return }
        visitLedgers.removeAll()
    }
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
            // A REALITYKIT AUDIO SOURCE THAT IS NOT IN A SCENE IS SILENT.
            //
            // `SpatialAudioManager.audioRoot` is where every positional cue's
            // source entity is parented, and nothing had ever added it to a
            // scene — so `playAudio` ran, logged success, and produced no
            // sound. Head-locked cues were unaffected (they go through
            // AVAudioEngine, which needs no scene), which is exactly why this
            // read as "spatial audio is broken" rather than "audio is broken".
            //
            // Mounting it here, with the root, ties its lifetime to the one
            // thing it depends on.
            if let root = immersiveSceneRoot {
                if audioManager.audioRoot.parent !== root {
                    root.addChild(audioManager.audioRoot)
                }
                // AND the sound must find its emitter. `entityLookup` was
                // declared and read but never assigned, so every cue authored
                // `attachToEntity` silently fell back to the unplaced branch —
                // a positional sound at the origin, which is the one place an
                // author never put it. Resolved through the loader on each
                // call because `materialize` rebuilds its anchor.
                audioManager.entityLookup = { [weak self] name in
                    self?.documentEntities.entity(named: name)
                }
            } else {
                audioManager.audioRoot.removeFromParent()
                audioManager.entityLookup = nil
            }

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
            // Spatial gates need the FULL head orientation — facing
            // uses pitch, which the leveled sample above strips.
            self.spatialTriggers.headTransformProvider = { [weak provider] in
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
        // After the executors: `self` is only usable once every stored `let`
        // has a value, and both of these read `spatialTriggers` off self.
        self.gateDetection = GateDetectionController(detector: spatialTriggers)
        self.interactions = InteractionController(detector: spatialTriggers)
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
        spatialTriggers.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }

        // Interactions: same registry, and responses handed straight back to
        // the engine so they run through the executors a step's actions use.
        sequenceEngine.interactionController = interactions
        interactions.entityProvider = { [weak self] name in
            self?.entityExecutor.entityRegistry[name]
        }
        interactions.perform = { [weak self] actions in
            self?.sequenceEngine.performActions(actions)
        }
        interactions.documentProvider = { [weak self] in
            self?.loadedExperience?.document
        }

        // THE GATE, AS THE SECOND CONSUMER OF ONE SEMANTIC ACTIVATION.
        interactions.offerToGate = { [weak self] entityName, trigger, interactionRan, isAccessible in
            self?.offerActivationToGate(entityName: entityName, trigger: trigger,
                                        interactionRan: interactionRan,
                                        isAccessible: isAccessible) ?? false
        }

        // An ACTIVE gate publishes an accessible equivalent on its target, and
        // withdraws it when it resolves. Event-driven, never polled.
        gateDetection.onGateActivated = { [weak self] gate in
            guard let self, let target = gate.targetEntity else { return }
            // A STORY-CONDITION GATE PUBLISHES NOTHING, and that is the
            // accessible behaviour rather than a gap in it. It is not waiting
            // for a person to do anything — it is waiting for a fact — so there
            // is no physical act to offer an equivalent FOR, and offering
            // "Continue" would let assistive technology bypass a condition the
            // author set. Every gate that asks for an act still gets one.
            guard let trigger = GateActivation.trigger(for: gate.type.authored) else { return }
            self.interactions.setGateAction(
                entityName: target,
                label: GateActivation.accessibleLabel(prompt: gate.prompt),
                trigger: trigger)
        }
        gateDetection.onGateResolved = { [weak self] in
            self?.interactions.clearGateActions()
        }

        // STORY STATE. The engine applies mutations into this session's store;
        // the store tells a waiting story-condition boundary that a fact it
        // waits for became true. Event-driven both ways, so nothing polls the
        // Chapter to notice a counter went up.
        sequenceEngine.storyState = storyState
        storyState.onChange = { [weak self] in
            self?.sequenceEngine.storyStateDidChange()
        }

        // EXPLORE. The clocks come from the engine, so there is no second timer
        // and nothing that keeps running while playback is paused.
        sequenceEngine.storyRegions = storyRegions
        storyRegions.runtimeClock = { [weak self] in
            // The engine's PAUSE-AWARE playback clock. It keeps advancing past
            // the authored total while the story is held, which is exactly what
            // makes it the runtime clock — and it subtracts paused time, so a
            // suspended experience does not age its region.
            self?.sequenceEngine.totalElapsed ?? 0
        }
        storyRegions.authoredClock = { [weak self] in
            // The Sequence clock. The engine clamps it at a step's end during a
            // gate wait, and that clamping IS the Explore hold.
            self?.sequenceEngine.sequenceAnimationTime ?? 0
        }
        storyRegions.releaseStory = { [weak self] in
            // The SAME call a tap makes. One way out of a hold.
            self?.sequenceEngine.satisfyGate()
        }
        storyRegions.setAnimationLoopOverride = { [weak self] entity, sampleTime in
            self?.entityExecutor.animationLoopOverrides[entity] = sampleTime
        }
        storyRegions.applyContinuation = { [weak self] target, behavior, phase in
            self?.applyStoryContinuation(target: target, behavior: behavior, phase: phase)
        }
        storyRegions.applyExitFade = { [weak self] target, seconds in
            self?.applyStoryExitFade(target: target, seconds: seconds)
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
        // AN AUTHORED NAVIGATION — from an Interaction response, or from any
        // step — reaches the ONE navigator here.
        //
        // Accessibility gets this for free: an accessible activation runs the
        // same `InteractionSpec.actions` a physical one does, so it produces
        // the same `.navigate` action, the same intent and the same transition.
        // There is no accessibility-specific Sequence change (Phase 6's rule).
        sequenceEngine.onNavigationRequested = { [weak self] intent in
            guard let self else { return }
            Task { @MainActor in
                // EXPLICIT NAVIGATION LEAVES AN EXPLORE REGION IMMEDIATELY.
                // Satisfying a Region's exit is a different act and does not
                // come through here — see `docs/EXPERIENCE_FLOW.md` §6.
                self.storyRegions.teardown()
                await self.navigate(intent, source: .host)
            }
        }

        // COMPLETION EMITS AN INTENT. IT DOES NOT NAVIGATE.
        //
        // This used to be a self-contained `while true` chain-walker that
        // resolved targets, applied presentation and called `playAndAwait`
        // inline — a second navigator, which Phase 8's Go To would have made a
        // third. `ExperienceNavigator` now decides, and this performs. Legacy
        // `autoAdvance` therefore behaves identically while sharing one
        // execution path with every new navigation kind.
        sequenceEngine.onSequenceComplete = { [weak self] completion in
            guard let self, let finished = self.activeSequenceId else { return }
            Task { @MainActor in
                let outcome = self.navigator.handleCompletion(
                    completion.authored,
                    from: finished,
                    exists: { self.sequenceFromLoadedDocument(id: $0) != nil },
                    start: { self.loadedExperience?.document.defaultSequenceId },
                    currentPosition: self.sequenceEngine.sequenceAnimationTime)
                await self.perform(outcome)
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
    /// ONE PERFORMER. `ExperienceNavigator` decides where to go; this is the
    /// only thing that starts a Sequence, so the immersive-space transition and
    /// the skybox-registration wait below cannot be bypassed by a second entry
    /// path. `startingAtStepIndex` is non-zero only for a resumed visit.
    public func playSequence(_ sequence: SequenceDefinition,
                             startingAtStepIndex startIndex: Int = 0) async {
        // A HOST THAT JUMPS STRAIGHT INTO A SEQUENCE still gets a session, so
        // its Story States hold their authored initial values rather than being
        // undefined. Guarded on the session FLAG, not on emptiness: a Chapter
        // that defines no Story State still has a session, and re-seeding on
        // every entry would reset the memory on the first Go To.
        if !storyState.isSessionActive { beginChapterPlaybackSession() }
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
        sequenceEngine.play(sequence: sequence, startingAtStepIndex: startIndex)
    }

    /// APPLY ONE CONTINUATION BEHAVIOUR, using the playback the runtime already
    /// has.
    ///
    /// Explore is an ORCHESTRATION layer: it starts and stops behaviour that
    /// already exists, and never becomes a second media engine. That is why
    /// there is no loop implementation here — a clip authored to loop keeps
    /// looping under `.continue` through `AVPlayerLooper`, which is the
    /// primitive the runtime already trims to the source window.
    private func applyStoryContinuation(
        target: StoryContinuationTarget,
        behavior: StoryContinuationBehavior,
        phase: StoryRegionController.ContinuationPhase
    ) {
        // An entity animation loop is handled by the sampling overlay, not here.
        guard case .occurrence(let actionId) = target else { return }
        guard let channel = channelForOccurrence(actionId) else {
            logger.warning("[explore] continuation target '\(actionId)' resolves to no channel — ignoring")
            return
        }

        let isVideo = isVideoOccurrence(actionId)

        switch (behavior, phase) {
        case (.hold, .enteringHold):
            // HOLD LAST FRAME. Pause where the authored pass left it; a clip
            // that already ended is already showing its last frame.
            //
            // VIDEO ONLY, AND SAID OUT LOUD. There is no per-channel audio
            // pause in this runtime — only `pauseAll()`, which would silence
            // channels the author asked to keep playing — so an audio hold
            // cannot be performed. The editors do not offer it
            // (`StoryContinuationCapabilities`); this logs the case that can
            // still arrive from a newer document or a hand edit, because the
            // previous behaviour was to route it through `videoManager`, get
            // nil, and leave the sound playing with no trace anywhere.
            if isVideo {
                videoManager.player(for: channel)?.pause()
            } else {
                logger.warning("[explore] hold is not available for audio channel '\(channel)' — it keeps playing")
            }
        case (.hold, .leavingHold):
            if isVideo { videoManager.player(for: channel)?.play() }
        case (.stop, .enteringHold):
            if isVideo { videoExecutor.stop(channel: channel) }
            else { audioExecutor.stop(channel: channel) }
        case (.continue, _):
            // Nothing to do: continuing means the content keeps running on its
            // own clock while authored time is parked, which is what it is
            // already doing.
            break
        case (.loop, _):
            // Not offered for media in this pass — see `docs/STORY_REGIONS.md`.
            // A clip authored to loop keeps looping under `.continue`.
            break
        case (.stop, .leavingHold), (.hold, _):
            break
        }
    }

    /// FADE THIS CONTENT OUT AS THE STORY RESUMES.
    ///
    /// Applied on the way out of a hold, using the per-channel gain command
    /// that has existed since long before Story Regions — the region owns no
    /// gain engine of its own. Audio only, which is the only place
    /// `StoryContinuationCapabilities` offers it.
    private func applyStoryExitFade(target: StoryContinuationTarget, seconds: TimeInterval) {
        guard case .occurrence(let actionId) = target,
              let channel = channelForOccurrence(actionId),
              !isVideoOccurrence(actionId) else { return }
        logger.info("[explore] fading '\(channel)' out over \(String(format: "%.2f", seconds))s on exit")
        audioExecutor.fade(channel: channel, to: 0, duration: seconds)
    }

    /// Is this occurrence a video? Video and audio share `channelForOccurrence`
    /// but not a single executor, and sending one's command to the other is how
    /// audio "hold" came to be a control that did nothing.
    private func isVideoOccurrence(_ actionId: String) -> Bool {
        guard let document = loadedExperience?.document else { return false }
        for sequence in document.sequences {
            for step in sequence.steps {
                for authored in step.authoredActions where authored.id == actionId {
                    switch authored.action {
                    case .playVideo, .prepareVideo: return true
                    default: return false
                    }
                }
            }
        }
        return false
    }

    /// The playback channel one authored occurrence plays on.
    ///
    /// Resolved from the DOCUMENT by stable action id, never from a filename or
    /// an index — an occurrence keeps its id through trim, slip, blade and
    /// retime, so a continuation override survives all of them.
    private func channelForOccurrence(_ actionId: String) -> String? {
        guard let document = loadedExperience?.document else { return nil }
        for sequence in document.sequences {
            for step in sequence.steps {
                for authored in step.authoredActions where authored.id == actionId {
                    switch authored.action {
                    case .playVideo(let v), .prepareVideo(let v): return v.channel
                    case .playAudio(let a): return a.channel
                    default: return nil
                    }
                }
            }
        }
        return nil
    }

    /// OFFER ONE SEMANTIC ACTIVATION TO THE WAITING GATE.
    ///
    /// The gate decides for itself whether this activation is the one it is
    /// waiting for — shared input, distinct consumers. The DECISION is
    /// `ChapterScript.GateActivation`, not a rule of this file's own: it
    /// determines whether a story advances, which is not something to discover
    /// on a headset. Sensing happens here; deciding does not.
    ///
    /// Returns true when the gate was satisfied.
    private func offerActivationToGate(
        entityName: String?, trigger: InteractionTrigger,
        interactionRan: Bool, isAccessible: Bool = false
    ) -> Bool {
        guard sequenceEngine.isWaiting, let gate = sequenceEngine.currentGate else { return false }

        let activation = SemanticActivation(
            entityName: entityName, trigger: trigger,
            interactionRan: interactionRan, isAccessible: isAccessible)
        // THE ACT **AND** WHAT THE STORY REMEMBERS. A condition an author added
        // to a gate is a requirement, so "tap the door once you have the key"
        // cannot be opened by the tap alone.
        guard GateActivation.satisfies(gate: gate.authored, activation: activation,
                                       state: storyState.ledger) else { return false }

        logger.info("[gate] satisfied by \(isAccessible ? "an accessible" : "a physical") \(trigger.kindName) activation on '\(entityName ?? "—")'")
        sequenceEngine.satisfyGate()
        return true
    }

    // MARK: - Performing navigation

    /// Carry out ONE navigation outcome. The only place a Sequence starts.
    ///
    /// The navigator decided; this performs. Presentation and backdrop are
    /// applied here because crossing a Sequence boundary is exactly where an
    /// immersive → windowed transition fires and where the previous Sequence's
    /// environment is torn down before the new one binds — which the old
    /// inline chain-walker also did, and which is the behaviour old Chapters
    /// depend on.
    @MainActor
    public func perform(_ outcome: NavigationOutcome) async {
        switch outcome {
        case .enter(let sequenceId, let visit, let resumingFrom):
            guard let next = sequenceFromLoadedDocument(id: sequenceId) else {
                logger.warning("[flow] '\(sequenceId)' vanished between decision and entry")
                return
            }
            // Put the visit we are leaving aside before `playSequence` tears it
            // down, so a later Resume can hand it back.
            if let outgoing = activeVisitID {
                visitLedgers[outgoing] = interactions.ledgerSnapshot
            }
            // DELEGATES TO THE ONE PERFORMER rather than starting the engine
            // itself. `playSequence` owns the immersive-space transition and
            // the skybox-registration wait, and a second start path that
            // skipped them is exactly the class of divergence this pass exists
            // to remove.
            //
            // RESUME ENTERS AT AN AUTHORED POSITION; a fresh visit starts at
            // the beginning. Restart and Resume must never share an
            // implementation ACCIDENTALLY — they share this one deliberately,
            // because entering is entering, and they differ in the VISIT the
            // navigator handed back.
            let startIndex = resumingFrom.map { stepIndex(of: next, atAuthoredTime: $0) } ?? 0
            await playSequence(next, startingAtStepIndex: startIndex)

            // ── WHAT A VISIT OWNS, RESTORED OR RE-ARMED ─────────────────────
            //
            // `playSequence` always re-arms. For a fresh visit that is correct
            // and this changes nothing. For a RESUMED one it is the bug: the
            // audience comes back to a Sequence where everything they had
            // already done is undone. Resume is the one case that carries a
            // position, and it is the one case that restores.
            activeVisitID = visit.id
            if resumingFrom != nil, let restored = visitLedgers[visit.id] {
                interactions.restoreLedger(restored)
            } else {
                visitLedgers[visit.id] = nil
            }
            pruneVisitLedgers()

        case .finish:
            sequenceEngine.stop()
            activeSequenceId = nil
            activeVisitID = nil
            visitLedgers.removeAll()
            // THE RUN IS OVER, so the session's memory ends with it. Nothing is
            // carried into the next run — that is what "a new playback session
            // resets Story State" means from the other side.
            storyState.endSession()

        case .stay:
            break

        case .refused(let refusal):
            // REFUSED, NOT REDIRECTED. Silently going somewhere plausible is
            // how an audience ends up in the wrong part of a story with no
            // trace of why.
            logger.warning("[flow] navigation refused: \(refusal.message)")
        }
    }

    /// Ask the navigator to do something, then do it.
    @MainActor
    public func navigate(_ intent: NavigationIntent, source: NavigationSource = .host) async {
        // `.start` IS THE BEGINNING OF A CHAPTER PLAYBACK SESSION. Seeding here
        // rather than inside the navigator keeps the navigator pure, and keeps
        // the one thing that resets Story State at the one place a Chapter
        // begins.
        if case .start = intent { beginChapterPlaybackSession() }

        let outcome = navigator.handle(
            NavigationRequest(intent: intent, source: source),
            exists: { self.sequenceFromLoadedDocument(id: $0) != nil },
            start: { self.loadedExperience?.document.defaultSequenceId },
            currentPosition: sequenceEngine.sequenceAnimationTime,
            // A BRANCH IS RESOLVED AGAINST THE RUNNING SESSION, by the shared
            // evaluator. Nothing here decides which case wins.
            storyState: storyState.ledger)
        await perform(outcome)
    }

    /// BEGIN A CHAPTER PLAYBACK SESSION. Every Story State returns to its
    /// authored initial value.
    ///
    /// The ONLY thing that resets Story State. Deliberately not called from
    /// `playSequence`, which starts a Sequence VISIT: Go To, Return and Restart
    /// all run through that, and every one of them must leave the story's memory
    /// exactly as the audience left it.
    @MainActor
    public func beginChapterPlaybackSession() {
        storyState.beginSession(loadedExperience?.document.storyState ?? [])
    }

    /// The step a resumed visit re-enters at.
    ///
    /// AUTHORED-BOUNDARY RESUME: playback resumes at the start of the step the
    /// visit had reached, not at an arbitrary sub-second offset. Reconstructing
    /// exact mid-action runtime state (a video part-played, a fade half-run, a
    /// gate part-dwelt) would need a retained live graph per suspended visit,
    /// which an hour-long chapter cannot afford. Documented as such rather than
    /// faked — see `docs/EXPERIENCE_FLOW.md` §Resume.
    private func stepIndex(of sequence: SequenceDefinition, atAuthoredTime time: TimeInterval) -> Int {
        var elapsed: TimeInterval = 0
        for (index, step) in sequence.steps.enumerated() {
            elapsed += step.duration
            if time < elapsed { return index }
        }
        return max(sequence.steps.count - 1, 0)
    }

    /// Arm the loaded document's interactions against the live scene.
    ///
    /// Document-wide, not Sequence-scoped — an interaction belongs to the
    /// object. Unrevealed objects are simply never hit: every watch checks that
    /// the entity is in the scene and enabled before it measures anything.
    public func installInteractions() {
        guard let document = loadedExperience?.document else { return }
        interactions.install(document: document)
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
