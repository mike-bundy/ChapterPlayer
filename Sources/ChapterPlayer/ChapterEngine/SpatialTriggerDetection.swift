//
//  SpatialTriggerDetection.swift
//  ChapterPlayer
//
//  ONE DETECTOR FOR "FACE IT", "WALK UP TO IT" AND "GRAB IT".
//
//  Two features now ask the same three questions of the same hardware: a step
//  GATE ("the story waits until you look at the radio") and an entity
//  INTERACTION ("tapping the radio plays the broadcast"). They mean different
//  things to the author and identical things to the sensors.
//
//  So the sensing lives here, once. `GateDetectionController` and
//  `InteractionController` are both consumers. A second facing/proximity/grab
//  implementation would double the device-QA surface — the one part of this
//  system that CANNOT be validated by unit tests — for no new capability.
//
//  WHAT MOVED, AND WHAT DID NOT.
//
//  The math is the gate detector's, unchanged: the same 12° base cone widened
//  by the target's angular radius, the same 1 s dwell that DECAYS rather than
//  resets, the same horizontal-plane proximity distance, the same scene-wide
//  manipulation subscription with an ancestry walk. Gates behave exactly as
//  they did; they simply no longer own the code.
//
//  MAESTRO DOES NOT KNOW WHERE THE VIEWER IS LOOKING.
//
//  SYSTEM-EYE-INPUT. `watchViewerFacing` measures the VIEWER'S FORWARD SPATIAL
//  DIRECTION — the device pose — held inside a cone around the target. visionOS
//  deliberately does not give an app precise eye movement or line of sight, and
//  nothing here attempts to obtain it. The platform's own hover effect DOES
//  respond to real eye input, privately, outside the app process; that signal
//  never arrives here and must never be reverse-engineered into a trigger. The
//  two are allowed to disagree, and a future agent must not "fix" that by
//  hunting for eye data.
//
//  ACTIVATION IS AN EDGE, NOT A LEVEL.
//
//  A gate is satisfied once and torn down. An interaction with
//  `lifetime == .everyTime` must be able to fire again — and "again" for a
//  continuous quantity is an EDGE. Standing inside a proximity radius is ONE
//  arrival, not twenty per second; holding your head toward an object is ONE
//  facing. So a repeating watch must see the condition go FALSE before it can
//  fire again. Non-repeating watches stop after the first activation, which is
//  what every gate wants.
//
//  AND A WATCH THAT ARMS WITH THE CONDITION ALREADY TRUE MUST NOT SYNTHESIZE AN
//  ACTIVATION.
//
//  A Sequence starting, an object being revealed, or an interaction being
//  enabled while the viewer already happens to be standing next to the plinth is
//  not the viewer approaching it. `armingPolicy` decides: proximity takes the
//  current state as its BASELINE and requires a real exit-and-enter, while
//  facing may begin its authored dwell from the moment it arms — because
//  completing a dwell IS a qualifying interval, whereas being inside a radius is
//  not an act at all.
//

import Combine
import Foundation
import OSLog
import RealityKit
import simd

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "SpatialTriggers"
)

@MainActor
public final class SpatialTriggerDetector {

    // MARK: - Tuning (defaults are the gate detector's, unchanged)

    /// Seconds the target must stay inside the facing cone before it activates.
    public var facingDwellDuration: TimeInterval = 1.0
    /// Base half-angle (radians) of the forward-direction cone. The effective
    /// cone per sample is max(this, the target's angular radius), so near/large
    /// targets are hit anywhere on their bounds.
    public var facingConeHalfAngle: Float = 12 * .pi / 180
    /// Trigger distance for proximity watches that do not author a radius.
    public var defaultProximityRadius: Float = 1.0

    // MARK: - Wiring

    /// Resolves an authored entity name to the live entity.
    public var entityProvider: ((String) -> Entity?)?

    /// UNLEVELED head sample — aim needs pitch, unlike the executor's yaw-only
    /// placement provider. Returning nil (tracking not ready) pauses detection
    /// for that tick; there is deliberately no simulator fallback pose, because
    /// a static pose could aim straight at a target and silently self-trigger.
    public var headTransformProvider: (() -> Transform?)?

    public init() {}

    // MARK: - Watch handle

    /// A running detection. Cancel it to stop; cancelling twice is harmless.
    public final class Watch {
        /// `fileprivate` rather than `private` so a grab watch can be handed
        /// its subscription later — it has to exist before the entity it
        /// subscribes to has mounted.
        fileprivate var task: Task<Void, Never>?
        fileprivate var subscription: (any Cancellable)?

        init(task: Task<Void, Never>? = nil, subscription: (any Cancellable)? = nil) {
            self.task = task
            self.subscription = subscription
        }

        public func cancel() {
            task?.cancel()
            task = nil
            subscription?.cancel()
            subscription = nil
        }

        deinit { task?.cancel(); subscription?.cancel() }
    }

    // MARK: - Viewer facing

    /// Watch for the viewer FACING `target` for `dwell` seconds.
    ///
    /// SYSTEM-EYE-INPUT: NOT eye tracking — see the file header. The device's forward
    /// direction held inside a cone whose half-angle is the larger of
    /// `facingConeHalfAngle` and the target's angular radius.
    ///
    /// - Parameter progress: 0…1 dwell progress, for a prompt ring. Called on
    ///   every tick; consumers that publish it should publish on CHANGE only.
    /// - Parameter repeats: keep watching after the first activation. The
    ///   viewer must LOSE the qualifying condition and re-acquire it before it
    ///   can fire again — holding still does not re-fire every dwell interval.
    public func watchViewerFacing(
        target: String,
        dwell: TimeInterval? = nil,
        repeats: Bool = false,
        progress: (@MainActor (Double) -> Void)? = nil,
        onTriggered: @escaping @MainActor () -> Void
    ) -> Watch {
        let needed = max(dwell ?? facingDwellDuration, 0.05)
        let tick: TimeInterval = 0.05
        let task = Task { @MainActor [weak self] in
            var dwelled: TimeInterval = 0
            var armed = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, !Task.isCancelled else { return }
                guard let entity = self.entityProvider?(target),
                      entity.scene != nil, entity.isEnabledInHierarchy,
                      let head = self.headTransformProvider?()
                else { continue }

                if self.isFacing(head: head, at: entity) {
                    dwelled += tick
                } else {
                    // DECAY, NOT RESET: a blink or a flick of the head must not
                    // throw away a second of patient facing.
                    dwelled = max(0, dwelled - tick * 2)
                    // Facing away is the edge that re-arms a repeating watch.
                    if dwelled == 0 { armed = true }
                }
                progress?(min(1, dwelled / needed))

                if armed, dwelled >= needed {
                    logger.info("Viewer-facing activation on '\(target)' after \(String(format: "%.2f", needed))s")
                    onTriggered()
                    if !repeats { return }
                    // Re-arming needs the condition to be LOST and re-acquired.
                    // Zeroing the dwell alone would re-fire every `needed`
                    // seconds for as long as the viewer held still, which is one
                    // continuous act reported as many.
                    armed = false
                    dwelled = 0
                    progress?(0)
                }
            }
        }
        return Watch(task: task)
    }

    private func isFacing(head: Transform, at entity: Entity) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        let toTarget = bounds.center - head.translation
        let distance = simd_length(toTarget)
        guard distance > 0.05 else { return true }
        let forward = head.rotation.act(SIMD3<Float>(0, 0, -1))
        let cosAngle = simd_dot(forward, toTarget / distance)
        let angle = acos(simd_clamp(cosAngle, -1, 1))
        let angularRadius = atan2(bounds.boundingRadius, distance)
        return angle <= max(facingConeHalfAngle, angularRadius)
    }

    // MARK: - Proximity

    /// How a watch behaves when the condition is ALREADY TRUE at the moment it
    /// starts — a Sequence beginning, an object being revealed, or an
    /// interaction being enabled while the viewer happens to be standing there.
    public enum ArmingPolicy: Sendable, Equatable {
        /// Take the current state as the BASELINE. The viewer must leave and
        /// come back for the first activation.
        ///
        /// What an entry EVENT means: being inside a radius is a state, not an
        /// act, so treating it as an arrival would fire narration at somebody
        /// who has not moved.
        case baseline
        /// Allow the condition to qualify immediately. Correct for a GATE,
        /// which asks "is this true?" rather than "did this just happen?" — and
        /// deliberately preserves the pre-existing gate behaviour.
        case immediate
    }

    /// Watch for the viewer coming within `radius` metres of `target`.
    ///
    /// Distance is HORIZONTAL (XZ): "walk up to it" must not depend on whether
    /// the target sits at floor height or eye height.
    ///
    /// An INTERACTION uses the entry EDGE (`arming: .baseline`); a GATE asks
    /// whether the condition holds (`arming: .immediate`, the default, which is
    /// what gates did before interactions existed). Shared geometry does not
    /// mean identical consumer semantics.
    ///
    /// A repeating watch re-arms only after the viewer leaves by a margin —
    /// without it, a viewer standing exactly on the boundary would retrigger
    /// every poll as tracking jitter crossed it.
    public func watchProximity(
        target: String,
        radius: Float? = nil,
        repeats: Bool = false,
        arming: ArmingPolicy = .immediate,
        onTriggered: @escaping @MainActor () -> Void
    ) -> Watch {
        let trigger = max(radius ?? defaultProximityRadius, 0.05)
        let release = trigger * 1.25
        let task = Task { @MainActor [weak self] in
            // `.baseline` starts DISARMED and lets the first sample decide: if
            // the viewer is already inside, arming waits for them to leave.
            var armed = arming == .immediate
            var baselineTaken = arming == .immediate
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                guard let entity = self.entityProvider?(target),
                      entity.scene != nil,
                      let head = self.headTransformProvider?()
                else { continue }

                let delta = entity.visualBounds(relativeTo: nil).center - head.translation
                let distance = simd_length(SIMD3<Float>(delta.x, 0, delta.z))

                if !baselineTaken {
                    // The first real sample establishes where the viewer
                    // already is. Outside → arm now; inside → wait for an exit.
                    baselineTaken = true
                    armed = distance > trigger
                    if !armed {
                        logger.info("Proximity watch on '\(target)' armed with the viewer already inside — waiting for a real approach")
                    }
                    continue
                }

                if armed, distance <= trigger {
                    logger.info("Proximity trigger on '\(target)': \(String(format: "%.2f", distance))m ≤ \(String(format: "%.2f", trigger))m")
                    onTriggered()
                    if !repeats { return }
                    armed = false
                } else if !armed, distance > release {
                    armed = true
                }
            }
        }
        return Watch(task: task)
    }

    // MARK: - Grab

    /// Watch for the viewer pinch-grabbing `target`.
    ///
    /// The target may not be in the scene yet (authored before its reveal
    /// lands), so this retries until it mounts, then subscribes once.
    ///
    /// Grab is inherently an EDGE — `ManipulationEvents.WillBegin` fires when a
    /// manipulation BEGINS, so holding the object does not re-fire and a
    /// release-then-grab is a second activation, with no bookkeeping needed
    /// here. `repeats` only decides whether the subscription survives the first
    /// one.
    public func watchGrab(
        target: String,
        repeats: Bool = false,
        onTriggered: @escaping @MainActor () -> Void
    ) -> Watch {
        let watch = Watch()
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let entity = self.entityProvider?(target), let scene = entity.scene {
                    self.subscribeGrab(target: entity, scene: scene, repeats: repeats,
                                       watch: watch, onTriggered: onTriggered)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        watch.task = task
        return watch
    }

    private func subscribeGrab(
        target: Entity,
        scene: RealityKit.Scene,
        repeats: Bool,
        watch: Watch,
        onTriggered: @escaping @MainActor () -> Void
    ) {
        // The trigger must be satisfiable even when the author never marked the
        // entity manipulable. Installing on demand leaves the entity grabbable
        // afterwards — acceptable: authoring a grab implies the object is meant
        // to be handled.
        if target.components[ManipulationComponent.self] == nil {
            ManipulationComponent.configureEntity(target)
            logger.info("Grab watch installed the manipulation stack on '\(target.name)'")
        }
        // Scene-wide subscription + ancestry walk: the event's entity can be a
        // DESCENDANT of the registered target (USDZ subtrees).
        let subscription = scene.subscribe(to: ManipulationEvents.WillBegin.self) { event in
            var node: Entity? = event.entity
            while let current = node {
                if current === target {
                    logger.info("Grab trigger on '\(target.name)'")
                    Task { @MainActor in
                        onTriggered()
                        if !repeats { watch.cancel() }
                    }
                    return
                }
                node = current.parent
            }
        }
        watch.subscription = subscription
    }
}
