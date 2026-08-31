//
//  SequenceDefinition.swift
//  SharedVisions
//
//  Declarative sequence and step definitions for the SequenceEngine.
//  Sequences are defined as data — the engine handles timing, controls, and reporting.
//

import Foundation
import simd
import ChapterScript

// MARK: - Sequence Definition

public struct SequenceDefinition: Sendable {
    public let id: String
    public let name: String
    public let phase: String
    /// Whether this sequence expects the immersive space open or a flat
    /// windowed scene. `AppModel.applySequencePresentation` toggles the
    /// space lifecycle in response to this when sequences switch.
    public let presentation: SequencePresentation
    /// Optional immersive backdrop (skybox video or USDZ scene) loaded
    /// while this sequence plays. Mirrors `ChapterScript.ImmersiveBackdropSpec`.
    public let immersiveBackdrop: SequenceBackdrop?
    /// Timed backdrop changes along the sequence. Each cue starts at an
    /// absolute sequence second and runs until the next one (or the sequence's
    /// end) — a cue has no end time by construction, which is what makes
    /// overlap unwritable.
    ///
    /// Empty means "use `immersiveBackdrop` for the whole sequence", i.e.
    /// exactly the behaviour of every document written before the track
    /// existed. `SequenceBackdropTimeline.effectiveCues` folds the two shapes
    /// into one so there is a single resolution path.
    ///
    /// Format types used directly (like `animationTracks`): these are pure
    /// data the backdrop driver resolves, not something the engine models.
    public let backdropTrack: [BackdropCue]
    /// Caption Tracks (FL-08): timed text at absolute Sequence seconds.
    public let captionTracks: [CaptionTrack]
    public let steps: [StepDefinition]
    /// Sequence-level keyframe animation tracks (format types used directly —
    /// the curves are pure data sampled by `SequenceAnimationEvaluator`).
    /// Keys sit at absolute seconds on the sequence's authored step grid.
    public let animationTracks: [EntityAnimationTrack]
    /// Sequence-level audio volume automation, one track per channel plus an
    /// optional `master` bus. Sampled on the same authored clock as
    /// `animationTracks`, so a volume ride holds at a gate exactly like a
    /// transform curve does.
    public let audioTracks: [AudioAutomationTrack]
    /// Muted destinations (FL-17) - a document fact; solo never arrives.
    public let mutedDestinations: [String]
    /// EXPLORE SPANS. Format types used directly, like `animationTracks` — pure
    /// authored data the region controller reads, not something the engine
    /// models. Empty = the Sequence is entirely Directed, which is every
    /// document written before Explore existed.
    public let storyRegions: [StoryRegion]
    /// SEQUENCE-LOCAL REST PLACEMENT (format type used directly): where
    /// each placed entity sits at rest IN THIS SEQUENCE, overriding its
    /// Chapter-global transform. Applied at sequence entry; entities
    /// without an entry keep (or return to) their Chapter rest. Empty =
    /// every document written before local placement existed.
    public let restPlacements: [String: TransformData]
    public let visibility: VisibilityState
    public let onComplete: CompletionAction

    public init(
        id: String,
        name: String,
        phase: String,
        presentation: SequencePresentation = .immersive,
        immersiveBackdrop: SequenceBackdrop? = nil,
        backdropTrack: [BackdropCue] = [],
        captionTracks: [CaptionTrack] = [],
        steps: [StepDefinition],
        animationTracks: [EntityAnimationTrack] = [],
        audioTracks: [AudioAutomationTrack] = [],
        mutedDestinations: [String] = [],
        storyRegions: [StoryRegion] = [],
        restPlacements: [String: TransformData] = [:],
        visibility: VisibilityState = VisibilityState(),
        onComplete: CompletionAction = .holdOnLastStep
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.presentation = presentation
        self.immersiveBackdrop = immersiveBackdrop
        self.backdropTrack = backdropTrack
        self.captionTracks = captionTracks
        self.steps = steps
        self.animationTracks = animationTracks
        self.audioTracks = audioTracks
        self.mutedDestinations = mutedDestinations
        self.storyRegions = storyRegions
        self.restPlacements = restPlacements
        self.visibility = visibility
        self.onComplete = onComplete
    }

    public var totalDuration: TimeInterval {
        steps.reduce(0) { $0 + $1.duration }
    }
}

public enum SequencePresentation: String, Sendable, Equatable {
    /// Full immersion — passthrough hidden, ideal for skyboxes and
    /// fully-authored 3D backdrops.
    case immersive
    /// Mixed reality — passthrough visible, with RealityKit content
    /// placing into world space. Use when a sequence wants 3D depth
    /// (anchored entities, USDZ setpieces) without replacing the
    /// user's real environment.
    case mixed
    /// No immersive space — only the flat windowed UI is visible.
    case windowed
}

/// Runtime-side mirror of `ChapterScript.ImmersiveBackdropSpec`. Carries the
/// fields needed by `VideoPlaybackManager` (for `.video`), the static-image
/// skybox path (for `.image`), or the document entity loader (for `.usdz`)
/// when the sequence activates. Reuses the `VideoLayout` and `ImmersiveField`
/// enums from `StepAction` so AppModel can hand them straight to
/// `VideoAction` without converting.
public enum SequenceBackdrop: Sendable, Equatable {
    case video(file: String, layout: VideoLayout, field: ImmersiveField, radius: Float, loop: Bool, audioEnabled: Bool)
    case image(file: String, field: ImmersiveField, radius: Float)
    case usdz(assetId: String)
}

// MARK: - Step Definition

public struct StepDefinition: Sendable {
    public let id: String
    public let name: String
    public let duration: TimeInterval
    public let actions: [StepAction]
    public let scheduledActions: [ScheduledAction]
    public let gate: StepGate?

    public init(
        id: String,
        name: String,
        duration: TimeInterval,
        actions: [StepAction],
        scheduledActions: [ScheduledAction] = [],
        gate: StepGate? = nil
    ) {
        self.id = id
        self.name = name
        self.duration = duration
        self.actions = actions
        self.scheduledActions = scheduledActions
        self.gate = gate
    }
}

// MARK: - Step Gate

public enum GateType: String, Sendable {
    case tap          // User interaction on headset
    case orchestrator // External controller
    case any          // Either works
    /// The viewer FACES targetEntity for a dwell time. SYSTEM-EYE-INPUT: not
    /// a claim about the eyes — measured from the device's forward direction.
    /// LEGACY-INTERACTION-VOCAB: the raw value matches `ChapterScript.GateType`.
    case viewerFacing = "gaze"   // LEGACY-INTERACTION-VOCAB
    case proximity    // Come within radius meters of targetEntity
    case grab         // Pinch-grab targetEntity
    /// The story's own memory is the condition; no act continues it.
    case storyCondition
}

extension GateType {
    /// The AUTHORED gate type this runtime case stands for.
    ///
    /// The runtime mirrors `ChapterScript.GateType` as its own enum, so the one
    /// place that decides whether an activation satisfies a gate
    /// (`ChapterScript.GateActivation`) needs a way across. EXHAUSTIVE with no
    /// `default`: a case added to either enum must be answered here rather than
    /// quietly mapping to `.tap`, because getting it wrong means a story that
    /// advances on the wrong act.
    public var authored: ChapterScript.GateType {
        switch self {
        case .tap:           return .tap
        case .orchestrator:  return .orchestrator
        case .any:           return .any
        case .viewerFacing:  return .viewerFacing
        case .proximity:     return .proximity
        case .grab:          return .grab
        case .storyCondition: return .storyCondition
        }
    }
}

public struct StepGate: Sendable {
    public let type: GateType
    public let timeout: TimeInterval?
    public let prompt: String?
    /// Entity the gate watches (viewer-facing / proximity / grab). Advisory — the
    /// consumer wires the matching detection to `satisfyGate()`.
    public let targetEntity: String?
    /// Trigger distance in meters for `.proximity` (default ~1 m).
    public let radius: Float?
    /// What the story must already remember before this boundary may pass.
    public let storyConditions: StoryConditionGroup?

    public init(
        type: GateType,
        timeout: TimeInterval? = nil,
        prompt: String? = nil,
        targetEntity: String? = nil,
        radius: Float? = nil,
        storyConditions: StoryConditionGroup? = nil
    ) {
        self.type = type
        self.timeout = timeout
        self.prompt = prompt
        self.targetEntity = targetEntity
        self.radius = radius
        self.storyConditions = storyConditions
    }

    /// The AUTHORED shape of this gate.
    ///
    /// Exists so every question about a gate — which act satisfies it, whether
    /// the story's memory continues it — is answered by the ONE authority in
    /// `ChapterScript.GateActivation`, rather than by a rule reimplemented here
    /// against the runtime mirror.
    public var authored: StepGateDTO {
        StepGateDTO(type: type.authored, timeout: timeout, prompt: prompt,
                    targetEntity: targetEntity, radius: radius,
                    storyConditions: storyConditions)
    }
}

// MARK: - Visibility State

/// Declarative entity visibility snapshot for SharedVisions primitives and example VFX.
/// Sequences declare their target visibility; the engine applies it on transition.
public struct VisibilityState: Sendable, Equatable {
    public var orb: Bool = false
    public var cube: Bool = false
    public var cylinder: Bool = false
    public var cone: Bool = false
    public var pulseRing: Bool = false
    public var sparkBurst: Bool = false

    public init(
        orb: Bool = false,
        cube: Bool = false,
        cylinder: Bool = false,
        cone: Bool = false,
        pulseRing: Bool = false,
        sparkBurst: Bool = false
    ) {
        self.orb = orb
        self.cube = cube
        self.cylinder = cylinder
        self.cone = cone
        self.pulseRing = pulseRing
        self.sparkBurst = sparkBurst
    }
}

// MARK: - Completion Action

public enum CompletionAction: Sendable, Equatable {
    case holdOnLastStep
    case transitionTo(phase: String, visibility: VisibilityState)
    case autoAdvance(nextSequenceId: String)
    case dismissToHome
    /// The full navigation vocabulary — Return, Restart, End and Go To.
    ///
    /// ── WHY THIS CASE EXISTS ────────────────────────────────────────────────
    ///
    /// `CompletionActionDTO.navigate` was added so a Sequence could END by
    /// returning or restarting, which the four legacy cases cannot express.
    /// This runtime mirror was not extended with it, and nothing noticed
    /// because ChapterPlayer only builds for visionOS: the Mac suites were
    /// green over a **broken device build**.
    ///
    /// Mapping it to `.holdOnLastStep` instead would have been worse than the
    /// build error — every authored Return, Restart and End would have become a
    /// silent hold on device while the editor showed the author what they
    /// asked for. A runtime type that cannot say what the format says is not a
    /// simplification; it is a lie with a shorter switch.
    case navigate(NavigationIntent)
}

// MARK: - Timing Function

public enum StepTimingFunction: String, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
}
