//
//  ChapterDefinition.swift
//  SharedVisions
//
//  Declarative chapter and step definitions for the ChapterEngine.
//  Chapters are defined as data — the engine handles timing, controls, and reporting.
//

import Foundation
import simd

// MARK: - Chapter Definition

public struct ChapterDefinition: Sendable {
    public let id: String
    public let name: String
    public let phase: String
    /// Whether this chapter expects the immersive space open or a flat
    /// windowed scene. `AppModel.applyChapterPresentation` toggles the
    /// space lifecycle in response to this when chapters switch.
    public let presentation: ChapterPresentation
    /// Optional immersive backdrop (skybox video or USDZ scene) loaded
    /// while this chapter plays. Mirrors `ChapterScript.ImmersiveBackdropSpec`.
    public let immersiveBackdrop: ChapterBackdrop?
    public let steps: [StepDefinition]
    public let visibility: VisibilityState
    public let onComplete: CompletionAction

    public init(
        id: String,
        name: String,
        phase: String,
        presentation: ChapterPresentation = .immersive,
        immersiveBackdrop: ChapterBackdrop? = nil,
        steps: [StepDefinition],
        visibility: VisibilityState = VisibilityState(),
        onComplete: CompletionAction = .holdOnLastStep
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.presentation = presentation
        self.immersiveBackdrop = immersiveBackdrop
        self.steps = steps
        self.visibility = visibility
        self.onComplete = onComplete
    }

    public var totalDuration: TimeInterval {
        steps.reduce(0) { $0 + $1.duration }
    }
}

public enum ChapterPresentation: String, Sendable, Equatable {
    /// Full immersion — passthrough hidden, ideal for skyboxes and
    /// fully-authored 3D backdrops.
    case immersive
    /// Mixed reality — passthrough visible, with RealityKit content
    /// placing into world space. Use when a chapter wants 3D depth
    /// (anchored entities, USDZ setpieces) without replacing the
    /// user's real environment.
    case mixed
    /// No immersive space — only the flat windowed UI is visible.
    case windowed
}

/// Runtime-side mirror of `ChapterScript.ImmersiveBackdropSpec`. Carries the
/// fields needed by `VideoPlaybackManager` (for `.video`), the static-image
/// skybox path (for `.image`), or the document entity loader (for `.usdz`)
/// when the chapter activates. Reuses the `VideoLayout` and `ImmersiveField`
/// enums from `StepAction` so AppModel can hand them straight to
/// `VideoAction` without converting.
public enum ChapterBackdrop: Sendable, Equatable {
    case video(file: String, layout: VideoLayout, field: ImmersiveField, radius: Float, loop: Bool)
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
}

public struct StepGate: Sendable {
    public let type: GateType
    public let timeout: TimeInterval?
    public let prompt: String?

    public init(type: GateType, timeout: TimeInterval? = nil, prompt: String? = nil) {
        self.type = type
        self.timeout = timeout
        self.prompt = prompt
    }
}

// MARK: - Visibility State

/// Declarative entity visibility snapshot for SharedVisions primitives and example VFX.
/// Chapters declare their target visibility; the engine applies it on transition.
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
    case autoAdvance(nextChapterId: String)
    case dismissToHome
}

// MARK: - Timing Function

public enum StepTimingFunction: String, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
}
