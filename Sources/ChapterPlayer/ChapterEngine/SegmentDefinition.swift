//
//  SegmentDefinition.swift
//  SharedVisions
//
//  Declarative segment and step definitions for the SegmentEngine.
//  Segments are defined as data — the engine handles timing, controls, and reporting.
//

import Foundation
import simd
import ChapterScript

// MARK: - Segment Definition

public struct SegmentDefinition: Sendable {
    public let id: String
    public let name: String
    public let phase: String
    /// Whether this segment expects the immersive space open or a flat
    /// windowed scene. `AppModel.applySegmentPresentation` toggles the
    /// space lifecycle in response to this when segments switch.
    public let presentation: SegmentPresentation
    /// Optional immersive backdrop (skybox video or USDZ scene) loaded
    /// while this segment plays. Mirrors `ChapterScript.ImmersiveBackdropSpec`.
    public let immersiveBackdrop: SegmentBackdrop?
    /// Timed backdrop changes along the segment. Each cue starts at an
    /// absolute segment second and runs until the next one (or the segment's
    /// end) — a cue has no end time by construction, which is what makes
    /// overlap unwritable.
    ///
    /// Empty means "use `immersiveBackdrop` for the whole segment", i.e.
    /// exactly the behaviour of every document written before the track
    /// existed. `SegmentBackdropTimeline.effectiveCues` folds the two shapes
    /// into one so there is a single resolution path.
    ///
    /// Format types used directly (like `animationTracks`): these are pure
    /// data the backdrop driver resolves, not something the engine models.
    public let backdropTrack: [BackdropCue]
    public let steps: [StepDefinition]
    /// Segment-level keyframe animation tracks (format types used directly —
    /// the curves are pure data sampled by `SegmentAnimationEvaluator`).
    /// Keys sit at absolute seconds on the segment's authored step grid.
    public let animationTracks: [EntityAnimationTrack]
    /// Segment-level audio volume automation, one track per channel plus an
    /// optional `master` bus. Sampled on the same authored clock as
    /// `animationTracks`, so a volume ride holds at a gate exactly like a
    /// transform curve does.
    public let audioTracks: [AudioAutomationTrack]
    public let visibility: VisibilityState
    public let onComplete: CompletionAction

    public init(
        id: String,
        name: String,
        phase: String,
        presentation: SegmentPresentation = .immersive,
        immersiveBackdrop: SegmentBackdrop? = nil,
        backdropTrack: [BackdropCue] = [],
        steps: [StepDefinition],
        animationTracks: [EntityAnimationTrack] = [],
        audioTracks: [AudioAutomationTrack] = [],
        visibility: VisibilityState = VisibilityState(),
        onComplete: CompletionAction = .holdOnLastStep
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.presentation = presentation
        self.immersiveBackdrop = immersiveBackdrop
        self.backdropTrack = backdropTrack
        self.steps = steps
        self.animationTracks = animationTracks
        self.audioTracks = audioTracks
        self.visibility = visibility
        self.onComplete = onComplete
    }

    public var totalDuration: TimeInterval {
        steps.reduce(0) { $0 + $1.duration }
    }
}

public enum SegmentPresentation: String, Sendable, Equatable {
    /// Full immersion — passthrough hidden, ideal for skyboxes and
    /// fully-authored 3D backdrops.
    case immersive
    /// Mixed reality — passthrough visible, with RealityKit content
    /// placing into world space. Use when a segment wants 3D depth
    /// (anchored entities, USDZ setpieces) without replacing the
    /// user's real environment.
    case mixed
    /// No immersive space — only the flat windowed UI is visible.
    case windowed
}

/// Runtime-side mirror of `ChapterScript.ImmersiveBackdropSpec`. Carries the
/// fields needed by `VideoPlaybackManager` (for `.video`), the static-image
/// skybox path (for `.image`), or the document entity loader (for `.usdz`)
/// when the segment activates. Reuses the `VideoLayout` and `ImmersiveField`
/// enums from `StepAction` so AppModel can hand them straight to
/// `VideoAction` without converting.
public enum SegmentBackdrop: Sendable, Equatable {
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
    case gaze         // Look at targetEntity (dwell)
    case proximity    // Come within radius meters of targetEntity
    case grab         // Pinch-grab targetEntity
}

public struct StepGate: Sendable {
    public let type: GateType
    public let timeout: TimeInterval?
    public let prompt: String?
    /// Entity the gate watches (gaze / proximity / grab). Advisory — the
    /// consumer wires the matching detection to `satisfyGate()`.
    public let targetEntity: String?
    /// Trigger distance in meters for `.proximity` (default ~1 m).
    public let radius: Float?

    public init(
        type: GateType,
        timeout: TimeInterval? = nil,
        prompt: String? = nil,
        targetEntity: String? = nil,
        radius: Float? = nil
    ) {
        self.type = type
        self.timeout = timeout
        self.prompt = prompt
        self.targetEntity = targetEntity
        self.radius = radius
    }
}

// MARK: - Visibility State

/// Declarative entity visibility snapshot for SharedVisions primitives and example VFX.
/// Segments declare their target visibility; the engine applies it on transition.
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
    case autoAdvance(nextSegmentId: String)
    case dismissToHome
}

// MARK: - Timing Function

public enum StepTimingFunction: String, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
}
