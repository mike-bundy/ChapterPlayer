//
//  GateDetection.swift
//  ChapterPlayer
//
//  Runtime detection for the spatial gate types. `SequenceEngine.waitAtGate`
//  notifies the wired `GateDetecting` when a gate activates; the controller
//  starts the matching watcher and calls back into `satisfyGate()` when the
//  user meets it:
//
//  - .gaze       head-aim cone + dwell timer (the OS never exposes the true
//                gaze ray, so "look at it" is approximated by head aim —
//                the cone widens with the target's angular size)
//  - .proximity  horizontal head-to-target distance vs the gate's radius
//  - .grab       ManipulationEvents.WillBegin on the target (installing the
//                manipulation stack on demand if the author didn't)
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

    // MARK: Tuning

    /// Seconds the target must stay inside the aim cone before a `.gaze`
    /// gate satisfies. Looking away decays the timer rather than resetting
    /// it, so a blink or jitter doesn't restart the dwell.
    public var gazeDwellDuration: TimeInterval = 1.0

    /// Base half-angle (radians) of the head-aim cone for `.gaze`. The
    /// effective cone per sample is max(this, the target's angular radius),
    /// so near/large targets are hit anywhere on their bounds.
    public var gazeConeHalfAngle: Float = 12 * .pi / 180

    /// Trigger distance for `.proximity` gates that don't author a radius.
    public var defaultProximityRadius: Float = 1.0

    // MARK: Wiring (set by ChapterPlayerCore)

    /// Resolves a gate's `targetEntity` name to the live entity.
    @ObservationIgnored public var entityProvider: ((String) -> Entity?)?

    /// UNLEVELED head sample — gaze aim needs pitch, unlike the executor's
    /// yaw-only placement provider. Returning nil (tracking not ready)
    /// pauses detection for that tick; there is deliberately no simulator
    /// fallback pose, because a static fallback could aim straight at a
    /// target and silently auto-satisfy the gate.
    @ObservationIgnored public var headTransformProvider: (() -> Transform?)?

    /// 0…1 dwell progress of the active `.gaze` gate. Hosts can render a
    /// progress ring next to the gate prompt.
    public private(set) var dwellProgress: Double = 0

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var manipulationSubscription: (any Cancellable)?

    public init() {}

    // MARK: GateDetecting

    public func gateDidStart(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void) {
        gateDidEnd()
        switch gate.type {
        case .tap, .orchestrator, .any:
            break
        case .gaze:
            startGazeDwell(gate, satisfy: satisfy)
        case .proximity:
            startProximityWatch(gate, satisfy: satisfy)
        case .grab:
            startGrabWatch(gate, satisfy: satisfy)
        }
    }

    public func gateDidEnd() {
        pollTask?.cancel()
        pollTask = nil
        manipulationSubscription?.cancel()
        manipulationSubscription = nil
        dwellProgress = 0
    }

    // MARK: - Gaze

    private func startGazeDwell(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void) {
        guard let targetName = gate.targetEntity else {
            logger.warning("Gaze gate has no targetEntity — only timeout/manual satisfy can clear it")
            return
        }
        let needed = gazeDwellDuration
        let tick: TimeInterval = 0.05
        pollTask = Task { @MainActor [weak self] in
            var dwell: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, !Task.isCancelled else { return }
                guard let entity = self.entityProvider?(targetName),
                      entity.scene != nil, entity.isEnabledInHierarchy,
                      let head = self.headTransformProvider?()
                else { continue }
                if self.isAimed(head: head, at: entity) {
                    dwell += tick
                } else {
                    dwell = max(0, dwell - tick * 2)
                }
                self.dwellProgress = min(1, dwell / needed)
                if dwell >= needed {
                    logger.info("Gaze gate satisfied: dwelled \(String(format: "%.2f", needed))s on '\(targetName)'")
                    satisfy()
                    return
                }
            }
        }
    }

    private func isAimed(head: Transform, at entity: Entity) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        let toTarget = bounds.center - head.translation
        let distance = simd_length(toTarget)
        guard distance > 0.05 else { return true }
        let forward = head.rotation.act(SIMD3<Float>(0, 0, -1))
        let cosAngle = simd_dot(forward, toTarget / distance)
        let angle = acos(simd_clamp(cosAngle, -1, 1))
        let angularRadius = atan2(bounds.boundingRadius, distance)
        return angle <= max(gazeConeHalfAngle, angularRadius)
    }

    // MARK: - Proximity

    private func startProximityWatch(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void) {
        guard let targetName = gate.targetEntity else {
            logger.warning("Proximity gate has no targetEntity — only timeout/manual satisfy can clear it")
            return
        }
        let radius = gate.radius ?? defaultProximityRadius
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                guard let entity = self.entityProvider?(targetName),
                      entity.scene != nil,
                      let head = self.headTransformProvider?()
                else { continue }
                // Horizontal-plane distance: "walk up to it" must not depend
                // on whether the target sits at floor height or eye height.
                let delta = entity.visualBounds(relativeTo: nil).center - head.translation
                let distance = simd_length(SIMD3<Float>(delta.x, 0, delta.z))
                if distance <= radius {
                    logger.info("Proximity gate satisfied: \(String(format: "%.2f", distance))m ≤ \(String(format: "%.2f", radius))m of '\(targetName)'")
                    satisfy()
                    return
                }
            }
        }
    }

    // MARK: - Grab

    private func startGrabWatch(_ gate: StepGate, satisfy: @escaping @MainActor @Sendable () -> Void) {
        guard let targetName = gate.targetEntity else {
            logger.warning("Grab gate has no targetEntity — only timeout/manual satisfy can clear it")
            return
        }
        // The target may not be in the scene yet (gate authored before its
        // reveal lands) — retry until it mounts, then subscribe once.
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let entity = self.entityProvider?(targetName), let scene = entity.scene {
                    self.subscribeGrab(target: entity, scene: scene, satisfy: satisfy)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func subscribeGrab(target: Entity, scene: RealityKit.Scene, satisfy: @escaping @MainActor @Sendable () -> Void) {
        // The gate must be satisfiable even when the author never marked the
        // entity manipulable. Installing on demand leaves the entity
        // grabbable after the gate — acceptable: a grab gate implies the
        // entity is meant to be handled.
        if target.components[ManipulationComponent.self] == nil {
            ManipulationComponent.configureEntity(target)
            logger.info("Grab gate installed manipulation stack on '\(target.name)'")
        }
        // Scene-wide subscription + ancestry walk: the event's entity can be
        // a descendant of the registered target (USDZ subtrees).
        manipulationSubscription = scene.subscribe(to: ManipulationEvents.WillBegin.self) { event in
            var node: Entity? = event.entity
            while let current = node {
                if current === target {
                    logger.info("Grab gate satisfied on '\(target.name)'")
                    Task { @MainActor in satisfy() }
                    return
                }
                node = current.parent
            }
        }
    }
}
