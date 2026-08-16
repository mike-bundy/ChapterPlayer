//
//  GateDetection.swift
//  ChapterPlayer
//
//  Runtime detection for the spatial GATE types. `SequenceEngine.waitAtGate`
//  notifies the wired `GateDetecting` when a gate activates; this starts the
//  matching watch and calls back into `satisfyGate()` when the user meets it.
//
//  THE SENSING ITSELF LIVES IN `SpatialTriggerDetector`, which entity
//  interactions also use — same cone, same dwell decay, same horizontal
//  proximity, same manipulation subscription. This file is now the GATE's
//  interpretation of those signals: exactly one watch at a time, satisfied
//  once, torn down on resolve.
//
//  .tap / .orchestrator / .any stay consumer-wired (SpatialTapGesture /
//  orchestrator message → `satisfyGate()`), exactly as before.
//

import Combine
import Foundation
import OSLog
import RealityKit
import simd

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "GateDetection"
)

// MARK: - Protocol

/// Engine-side hook for spatial gate detection. `SequenceEngine` calls
/// `gateDidStart` when a gate begins waiting and `gateDidEnd` when the gate
/// resolves for any reason (satisfied, timed out, step loop cancelled).
@MainActor
public protocol GateDetecting: AnyObject {
    /// Start whatever detection matches the gate's type. Call `satisfy`
    /// (at most once) when the user meets the gate.
    func gateDidStart(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void)
    /// Stop all detection. Idempotent.
    func gateDidEnd()
}

// MARK: - Controller

@MainActor
@Observable
public final class GateDetectionController: GateDetecting {

    /// The shared sensing layer. Exposed so `ChapterPlayerCore` can wire ONE
    /// detector into both this and `InteractionController` — two detectors
    /// polling the same head pose would be two answers to one question.
    @ObservationIgnored public let detector: SpatialTriggerDetector

    // MARK: Tuning (forwarded — the values live on the detector)

    public var facingDwellDuration: TimeInterval {
        get { detector.facingDwellDuration }
        set { detector.facingDwellDuration = newValue }
    }
    public var facingConeHalfAngle: Float {
        get { detector.facingConeHalfAngle }
        set { detector.facingConeHalfAngle = newValue }
    }
    public var defaultProximityRadius: Float {
        get { detector.defaultProximityRadius }
        set { detector.defaultProximityRadius = newValue }
    }

    // MARK: Wiring

    /// Resolves a gate's `targetEntity` name to the live entity.
    @ObservationIgnored public var entityProvider: ((String) -> Entity?)? {
        get { detector.entityProvider }
        set { detector.entityProvider = newValue }
    }

    /// UNLEVELED head sample — facing needs pitch, unlike the executor's
    /// yaw-only placement provider.
    @ObservationIgnored public var headTransformProvider: (() -> Transform?)? {
        get { detector.headTransformProvider }
        set { detector.headTransformProvider = newValue }
    }

    /// 0…1 dwell progress of the active `.viewerFacing` gate. Hosts can render
    /// a progress ring next to the gate prompt.
    public private(set) var dwellProgress: Double = 0

    @ObservationIgnored private var watch: SpatialTriggerDetector.Watch?

    /// A gate began waiting / resolved. `ChapterPlayerCore` uses these to
    /// publish and withdraw the gate's ACCESSIBLE EQUIVALENT on its target —
    /// a gate blocks the story, so a viewer who cannot perform the physical act
    /// must have another route or the chapter is over for them.
    ///
    /// Deliberately separate from `onGateStarted`/`onGateEnded`, which remain
    /// the consumer's prompt UI.
    @ObservationIgnored public var onGateActivated: ((StepGate) -> Void)?
    @ObservationIgnored public var onGateResolved: (() -> Void)?

    public init(detector: SpatialTriggerDetector = SpatialTriggerDetector()) {
        self.detector = detector
    }

    // MARK: GateDetecting

    public func gateDidStart(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void) {
        gateDidEnd()
        onGateActivated?(gate)
        switch gate.type {
        case .tap, .orchestrator, .any:
            break
        case .storyCondition:
            // NOTHING TO SENSE. This boundary waits on what the Chapter
            // remembers, and `SequenceEngine` releases it from the Story State
            // store the moment a fact it waits for becomes true. Installing a
            // spatial watch here would be a detector for an act nobody has to
            // perform.
            break
        case .viewerFacing:
            guard let target = gate.targetEntity else {
                logger.warning("Viewer-facing gate has no targetEntity — only timeout/manual satisfy can clear it")
                return
            }
            watch = detector.watchViewerFacing(
                target: target,
                progress: { [weak self] progress in
                    // Published, so it is written only when it CHANGES — the
                    // ring redraws twenty times a second otherwise.
                    guard let self, self.dwellProgress != progress else { return }
                    self.dwellProgress = progress
                },
                onTriggered: satisfy
            )
        case .proximity:
            guard let target = gate.targetEntity else {
                logger.warning("Proximity gate has no targetEntity — only timeout/manual satisfy can clear it")
                return
            }
            // `.immediate`, deliberately: a GATE asks "is this true?", so a
            // viewer already standing inside the radius when the gate begins
            // satisfies it at once. That is the behaviour gates had before
            // interactions existed, and this closure does not change it — an
            // Interaction's entry EDGE is a different question with a different
            // policy. Shared geometry, distinct consumer semantics.
            watch = detector.watchProximity(target: target, radius: gate.radius,
                                            arming: .immediate, onTriggered: satisfy)
        case .grab:
            guard let target = gate.targetEntity else {
                logger.warning("Grab gate has no targetEntity — only timeout/manual satisfy can clear it")
                return
            }
            watch = detector.watchGrab(target: target, onTriggered: satisfy)
        }
    }

    public func gateDidEnd() {
        watch?.cancel()
        watch = nil
        dwellProgress = 0
        onGateResolved?()
    }
}
