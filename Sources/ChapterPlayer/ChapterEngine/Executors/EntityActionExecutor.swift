//
//  EntityActionExecutor.swift
//  SharedVisions
//
//  Handles entity show/hide/move/scale/fade/reveal/gesture/persist actions from SequenceEngine.
//  Wraps RealityKit Entity manipulation.
//

import RealityKit
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "EntityActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol EntityActionExecutorProtocol {
    func showEntity(named: String)
    func hideEntity(named: String)
    func moveEntity(_ action: MoveAction)
    func scaleEntity(named: String, multiplier: Float, duration: TimeInterval, timing: StepTimingFunction)
    func fadeEntity(_ action: FadeAction)
    func revealEntity(_ action: RevealAction)
    func enableGesture(named: String)
    func disableGesture(named: String)
    func resetAllEntities()
    func persistEntity(named: String)
    func unpersistEntity(named: String)
    func beginMotion(_ action: AnimateMotionAction)
    func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO)
    func clearAllMotions()
    /// Clear only the STEP-SCOPED motions. See the implementation for why
    /// Motion Actions 2.0 behaviors are deliberately not among them.
    func clearStepMotions()
    func applyActiveMotions(stepElapsed: TimeInterval, totalElapsed: TimeInterval)
    func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?)
}

/// Default no-op so existing conformers outside this package keep compiling;
/// the real executor overrides it.
public extension EntityActionExecutorProtocol {
    func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?) {}
    func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO) {}
    /// Defaults to the old behaviour for conformers outside this package, which
    /// never had Motion Actions 2.0 to keep alive in the first place.
    func clearStepMotions() { clearAllMotions() }
}

// MARK: - Implementation

@MainActor
public final class EntityActionExecutor: EntityActionExecutorProtocol {


    public init() {}
    /// Registry of named entities. Populated by ImmersiveView during setup.
    public var entityRegistry: [String: Entity] = [:]

    /// Original transforms for reset support.
    private var originalTransforms: [String: Transform] = [:]

    /// Names of entities that should survive sequence transitions.
    /// Populated by `.persistEntity` step actions; respected by `resetAllEntities()`.
    public var persistedEntityNames: Set<String> = []

    /// Per-entity active motion curves. Populated by `.animateMotion` step actions;
    /// cleared at every step boundary by `clearAllMotions()`.
    /// `applyActiveMotions(stepElapsed:totalElapsed:)` samples each entry per frame
    /// and writes the result back to the entity's transform.
    ///
    /// `startedAt` is the AUTHORED sequence time at which the motion began, and
    /// it is what progress is measured from. It used to be measured from the
    /// STEP's start instead, which meant a motion scheduled 5s into a 10s step
    /// began life already 50% complete — while the editor's `ScrubCompositor`
    /// drew the same motion from its beginning. The author saw one thing and
    /// the headset did another. Both now call `MotionProgress`.
    ///
    /// nil when no authored clock was available at registration; the sampler
    /// then falls back to the old step-relative behaviour rather than freezing.
    private var activeMotions: [String: (action: AnimateMotionAction, startedAt: TimeInterval?)] = [:]

    /// MOTION ACTIONS 2.0 — active behaviors per entity, MANY per entity
    /// (a Move In and a Scale In are two behaviors that compose), each with
    /// the authored time it started. Cleared with the legacy motions.
    ///
    /// A behavior is an OFFSET: it is re-applied every frame on top of the
    /// pose the authored layers produce, never accumulated into the entity —
    /// so it cannot drift, and removing it restores the authored pose exactly.
    private var activeBehaviors: [String: [(behavior: ChapterScript.MotionBehaviorDTO, startedAt: TimeInterval?)]] = [:]

    /// Sequence-level animation tracks, registered once at sequence start and
    /// sampled every frame on the AUTHORED sequence clock (`animationClock`) —
    /// not wall time, so gates and pauses hold curves instead of skipping
    /// them. Independent of the per-step `activeMotions` above (which stay
    /// for legacy documents).
    private var sequenceAnimationTracks: [EntityAnimationTrack] = []
    private var animationClock: (@MainActor () -> TimeInterval)?

    /// Closure that samples the user's head transform at call time.
    /// Wired by ImmersiveView during setup. Returns nil when tracking is unavailable.
    public var headTransformProvider: (() -> Transform?)?

    /// Fallback head transform for simulator / tracking-unavailable.
    /// Simulated eye height at world origin, facing -Z.
    private let simulatorFallbackTransform = Transform(
        scale: .one,
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
        translation: SIMD3<Float>(0, 1.5, 0)
    )

    /// Register an entity with a name for the sequence engine to reference.
    public func register(_ entity: Entity, name: String) {
        entityRegistry[name] = entity
        originalTransforms[name] = entity.transform
    }

    /// Drop a registered entity name. Called by `DocumentEntityLoader.unload`
    /// when the loaded document changes (live hot-reload, project switch),
    /// so old sequence actions referencing a stale name fail safely instead
    /// of operating on the deleted Entity.
    public func unregister(name: String) {
        entityRegistry.removeValue(forKey: name)
        originalTransforms.removeValue(forKey: name)
    }

    /// Re-baseline the reset pose for `name` to a new AUTHORED transform.
    /// Live editors call this when a committed edit changes the entity's
    /// base transform (the snapshot is otherwise captured only at
    /// materialize, so every replay's `resetAllEntities` would snap the
    /// entity back to its materialize-time pose — the "default placement"
    /// for assets imported and then positioned in-session).
    public func setOriginalTransform(_ transform: Transform, name: String) {
        guard originalTransforms[name] != nil else { return }
        originalTransforms[name] = transform
    }

    public func showEntity(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("showEntity: '\(name)' not found in registry")
            return
        }
        entity.isEnabled = true
        // A stale fully-transparent OpacityComponent (video preheat, a
        // gated video start that never revealed, or a fadeEntity-to-0 used
        // as a hide) makes "show" a silent no-op — the entity is enabled
        // but renders nothing. Show means visible: snap effectively-zero
        // opacity back to 1. Partial opacities are authored state and are
        // left alone.
        if let opacity = entity.components[OpacityComponent.self]?.opacity,
           opacity <= 0.001 {
            entity.components[OpacityComponent.self]?.opacity = 1
        }
        triggerParticleBurstIfNeeded(on: entity)
        logger.debug("Show entity: \(name)")
    }

    /// Non-looping particle entities (`ParticleBurstOnRevealComponent`)
    /// are built idle with a preset-sized `burstCount`; showing/revealing
    /// them fires the one-shot burst. Re-revealing re-bursts.
    private func triggerParticleBurstIfNeeded(on entity: Entity) {
        guard entity.components.has(ParticleBurstOnRevealComponent.self),
              var emitter = entity.components[ParticleEmitterComponent.self] else { return }
        emitter.burst()
        entity.components.set(emitter)
    }

    public func hideEntity(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("hideEntity: '\(name)' not found in registry")
            return
        }
        entity.isEnabled = false
        logger.debug("Hide entity: \(name)")
    }

    public func moveEntity(_ action: MoveAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("moveEntity: '\(action.entity)' not found in registry")
            return
        }

        let timing = action.timing.animationTimingFunction

        if let headOffset = action.headRelativePosition {
            let worldTarget = resolveHeadWorldPosition(offset: headOffset, headYOnly: action.headYOnly)

            var targetScale = entity.scale(relativeTo: nil)
            var targetRotation = entity.orientation(relativeTo: nil)

            if let multiplier = action.scaleMultiplier {
                targetScale *= multiplier
            }
            if let absolute = action.absoluteScale {
                targetScale = absolute
            }
            if let absRot = action.absoluteRotation {
                targetRotation = absRot
            } else if let offset = action.rotationOffset {
                targetRotation = offset * targetRotation
            }

            let targetTransform = Transform(
                scale: targetScale,
                rotation: targetRotation,
                translation: worldTarget
            )

            entity.move(to: targetTransform, relativeTo: nil, duration: action.duration, timingFunction: timing)

            let mode = action.headYOnly ? "headYOnly" : "headRelative"
            logger.debug("Move entity (\(mode)): \(action.entity) offset=\(headOffset) → world=\(worldTarget)")
        } else {
            // Parent-space positioning
            var targetPosition = entity.position(relativeTo: entity.parent)
            var targetScale = entity.scale
            var targetRotation = entity.orientation

            if let offset = action.positionOffset {
                targetPosition += offset
            }
            if let absolute = action.absolutePosition {
                targetPosition = absolute
            }
            if let multiplier = action.scaleMultiplier {
                targetScale *= multiplier
            }
            if let absolute = action.absoluteScale {
                targetScale = absolute
            }
            if let absRot = action.absoluteRotation {
                targetRotation = absRot
            } else if let offset = action.rotationOffset {
                targetRotation = offset * targetRotation
            }

            let targetTransform = Transform(
                scale: targetScale,
                rotation: targetRotation,
                translation: targetPosition
            )

            entity.move(to: targetTransform, relativeTo: entity.parent, duration: action.duration, timingFunction: timing)

            logger.debug("Move entity: \(action.entity) over \(String(format: "%.1f", action.duration))s")
        }
    }

    public func scaleEntity(named name: String, multiplier: Float, duration: TimeInterval, timing: StepTimingFunction) {
        guard let entity = entityRegistry[name] else {
            logger.warning("scaleEntity: '\(name)' not found in registry")
            return
        }

        let targetTransform = Transform(
            scale: entity.scale * multiplier,
            rotation: entity.orientation,
            translation: entity.position(relativeTo: entity.parent)
        )

        entity.move(
            to: targetTransform,
            relativeTo: entity.parent,
            duration: duration,
            timingFunction: timing.animationTimingFunction
        )

        logger.debug("Scale entity: \(name) by \(multiplier)× over \(String(format: "%.1f", duration))s")
    }

    public func fadeEntity(_ action: FadeAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("fadeEntity: '\(action.entity)' not found in registry")
            return
        }
        entity.fadeOpacity(to: action.opacity, duration: action.duration, timing: action.timing.animationTimingFunction)
        logger.debug("Fade entity: \(action.entity) to opacity \(action.opacity) over \(String(format: "%.1f", action.duration))s")
    }

    public func revealEntity(_ action: RevealAction) {
        guard let entity = entityRegistry[action.entity] else {
            logger.warning("revealEntity: '\(action.entity)' not found in registry")
            return
        }

        // 1. Snap invisible (synchronous — no frame rendered between this and enable)
        entity.fadeOpacity(to: 0, duration: 0)

        // 2. Position
        if let headOffset = action.headRelativePosition {
            let worldTarget = resolveHeadWorldPosition(offset: headOffset, headYOnly: action.headYOnly)
            var targetScale = entity.scale(relativeTo: nil)
            if let scale = action.scale { targetScale = scale }
            let targetTransform = Transform(
                scale: targetScale,
                rotation: entity.orientation(relativeTo: nil),
                translation: worldTarget
            )
            entity.move(to: targetTransform, relativeTo: nil, duration: 0)
        } else if let position = action.position {
            var targetScale = entity.scale
            if let scale = action.scale { targetScale = scale }
            let targetTransform = Transform(
                scale: targetScale,
                rotation: entity.orientation,
                translation: position
            )
            entity.move(to: targetTransform, relativeTo: entity.parent, duration: 0)
        }

        // 3. Scale (only if not already applied in position block above)
        if let scale = action.scale, action.headRelativePosition == nil, action.position == nil {
            entity.scale = scale
        }

        // 4. Enable (still invisible — opacity 0)
        entity.isEnabled = true

        // 5. Fade in (or cut-in if duration == 0)
        entity.fadeOpacity(to: 1.0, duration: action.fadeIn)

        // 6. Optional hand manipulation — make the entity grabbable /
        //    movable / rotatable / scalable by the viewer. RealityKit's
        //    ManipulationComponent.configureEntity wires up the collision
        //    + input-target + hover-effect components it needs.
        if action.manipulable {
            ManipulationComponent.configureEntity(entity)
        }

        // 7. Non-looping particle emitters fire their one-shot burst now.
        triggerParticleBurstIfNeeded(on: entity)

        logger.debug("Reveal entity: \(action.entity) fadeIn=\(String(format: "%.1f", action.fadeIn))s manipulable=\(action.manipulable)")
    }

    // MARK: - Head Position Helper

    private func resolveHeadWorldPosition(offset: SIMD3<Float>, headYOnly: Bool) -> SIMD3<Float> {
        let headTransform: Transform
        if let sampled = headTransformProvider?() {
            headTransform = sampled
        } else {
            logger.info("Head tracking unavailable — using simulator fallback position")
            headTransform = simulatorFallbackTransform
        }

        if headYOnly {
            let headWorldY = headTransform.translation.y
            return SIMD3<Float>(offset.x, headWorldY + offset.y, offset.z)
        } else {
            return headTransform.worldPosition(forLocalOffset: offset)
        }
    }

    public func resetAllEntities() {
        clearAllMotions()
        for (name, originalTransform) in originalTransforms {
            guard let entity = entityRegistry[name] else { continue }
            if persistedEntityNames.contains(name) {
                logger.debug("resetAllEntities: skipping persisted entity '\(name)'")
                continue
            }
            entity.move(
                to: originalTransform,
                relativeTo: entity.parent,
                duration: 0
            )
            if entity.components.has(OpacityComponent.self) {
                entity.opacity = 1.0
            }
            // Return to the canonical "default" state — hidden until a sequence action reveals it.
            entity.isEnabled = false
        }
        logger.info("Reset all entity transforms and disabled non-persisted entities")
    }

    // MARK: - Active motion

    public func beginMotionBehavior(_ behavior: ChapterScript.MotionBehaviorDTO) {
        guard entityRegistry[behavior.entity] != nil else {
            logger.warning("beginMotionBehavior: entity '\(behavior.entity)' not found in registry")
            return
        }
        activeBehaviors[behavior.entity, default: []].append((behavior, animationClock?()))
    }

    public func beginMotion(_ action: AnimateMotionAction) {
        guard entityRegistry[action.entity] != nil else {
            logger.warning("beginMotion: entity '\(action.entity)' not found in registry")
            return
        }
        // Stamp the authored clock NOW, so progress is measured from when this
        // motion actually started rather than from whenever its step did.
        activeMotions[action.entity] = (action, animationClock?())
        logger.debug("beginMotion: \(action.entity) (duration \(action.duration)s)")
    }

    public func clearAllMotions() {
        if !activeMotions.isEmpty {
            logger.debug("Cleared \(self.activeMotions.count) active motion(s)")
        }
        activeMotions.removeAll(keepingCapacity: true)
        activeBehaviors.removeAll(keepingCapacity: true)
    }

    /// A STEP BOUNDARY ENDS A LEGACY MOTION AND DOES NOT END A BEHAVIOR.
    ///
    /// `animateMotion` is per-step by design — it is sampled on `stepElapsed`
    /// and the engine's comment at the call site says so. Motion Actions 2.0
    /// behaviors were swept into the same call only because they were added to
    /// the dictionary next door, and clearing them at a boundary is wrong for
    /// three reasons:
    ///
    ///   1. A behavior is timed on the AUTHORED SEQUENCE CLOCK through
    ///      `startedAt` + `MotionProgress`, whose progress SATURATES at 1. It
    ///      has a natural end of its own and does not need a boundary to stop
    ///      it; past that point it simply holds its final offset.
    ///   2. Clearing one restores the authored rest pose, so an EXIT that had
    ///      finished faded the object out and then a step boundary popped it
    ///      back to full opacity at its original position.
    ///   3. The editor never scoped them this way. `SequencePreviewCompositor`
    ///      walks every timed entry at or before the playhead with no step
    ///      scoping at all, so the Mac showed a behavior persisting while the
    ///      headset dropped it — the editor and the device disagreeing about
    ///      the same authored fact, which is the failure the `startedAt` work
    ///      above this file was done to remove.
    ///
    /// A behavior is re-applied as an OFFSET from the authored base every
    /// frame and never accumulates, so keeping one costs nothing and cannot
    /// drift.
    public func clearStepMotions() {
        if !activeMotions.isEmpty {
            logger.debug("Cleared \(self.activeMotions.count) step motion(s)")
        }
        activeMotions.removeAll(keepingCapacity: true)
    }

    public func setSequenceAnimation(tracks: [EntityAnimationTrack], clock: (@MainActor () -> TimeInterval)?) {
        sequenceAnimationTracks = tracks.filter { $0.hasAnyKeys }
        animationClock = clock
        if !sequenceAnimationTracks.isEmpty {
            logger.info("Sequence animation: \(self.sequenceAnimationTracks.count) track(s) registered")
        }
    }

    /// MOTION ACTIONS 2.0 — compose every active behavior onto the pose the
    /// authored layers just produced.
    ///
    /// Runs AFTER `applySequenceAnimationTracks()` on purpose: the track (or,
    /// for an unkeyed entity, the registered rest transform) is the base, and
    /// a behavior only ever ADDS to it. The base is read from AUTHORED state —
    /// the animation track or `originalTransforms` — never from the entity's
    /// current on-screen transform, which would fold the previous frame's
    /// offset back in and make the object walk away over time.
    private func applyActiveBehaviors() {
        guard !activeBehaviors.isEmpty else { return }
        let authoredNow = animationClock?()
        // NO LIVE HEAD YAW, DELIBERATELY. The scene root is rebased to the
        // head when a Sequence starts (`rebaseSceneRootToHead`), so the root's
        // own axes ARE the viewer's axes — and that rebase is the stable one
        // an author aimed at. Reading the head every frame instead would make
        // "enter from the left" depend on where the viewer happened to be
        // looking at the moment the motion fired, so the same authored Chapter
        // would play differently on every run and would never match the
        // editor. `nil` means "viewer space is this space", which is exactly
        // what the Mac Viewer also assumes (camera at the origin facing -Z).
        let viewerYaw: Float? = nil

        for (name, entries) in activeBehaviors {
            guard let entity = entityRegistry[name] else { continue }
            // The authored base: whatever the track/rest layer produced. For a
            // keyed entity `applySequenceAnimationTracks` has just written it;
            // for an unkeyed one it is the registered rest transform.
            //
            // RESOLVED BEFORE the behaviors rather than after: an orbit is
            // defined by its centre, so the resolver needs to know where the
            // object sits.
            let resolvedBase = sequenceAnimationTracks.contains { $0.entity == name }
                ? entity.transform
                : (originalTransforms[name] ?? entity.transform)
            let restForMotion = resolvedBase.translation

            var combined = ChapterScript.MotionOffset.identity
            for (behavior, startedAt) in entries {
                let progress: Float
                if let startedAt, let authoredNow {
                    // AN AMBIENT BEHAVIOR IS NOT A RAMP. `MotionProgress`
                    // clamps at 1, which is right for an entrance and would
                    // freeze a cycling cue after one period, so an ambient
                    // behavior is handed ELAPSED CYCLES instead and the
                    // resolver takes the phase modulo one.
                    if behavior.kind == .ambient {
                        // Elapsed CYCLES. The resolver takes the phase modulo
                        // one and returns identity once the authored span has
                        // run out, so a trimmed cue stops rather than freezing
                        // mid-phase.
                        let period = max(ChapterScript.MotionProgress.minimumDuration,
                                         behavior.duration)
                        progress = Float((authoredNow - startedAt) / period)
                    } else {
                        progress = ChapterScript.MotionProgress.progress(
                            startTime: startedAt, now: authoredNow, duration: behavior.duration)
                    }
                } else {
                    // With no authored clock an ambient behavior sits at its
                    // authored pose rather than at some arbitrary point in a
                    // cycle it cannot measure.
                    progress = behavior.kind == .ambient ? 0 : 1
                }
                combined = ChapterScript.MotionOffset.combine(
                    combined,
                    ChapterScript.MotionBehaviorResolver.offset(
                        behavior, progress: progress, viewerYaw: viewerYaw,
                        restPosition: restForMotion)
                )
            }

            let base = resolvedBase

            entity.position = base.translation + combined.positionDelta
            entity.scale = base.scale * combined.scaleMultiplier
            // ROTATION COMPOSES ON TOP OF THE AUTHORED ORIENTATION, in the
            // entity's own space, so a Slow Spin turns an object about its own
            // up axis wherever the author aimed it. Skipped entirely when
            // there is none, so nothing that does not spin pays for a
            // quaternion multiply every frame.
            if combined.rotationDelta != .zero {
                let radians = combined.rotationDelta * (.pi / 180)
                let spin = simd_quatf(angle: radians.y, axis: [0, 1, 0])
                    * simd_quatf(angle: radians.x, axis: [1, 0, 0])
                    * simd_quatf(angle: radians.z, axis: [0, 0, 1])
                entity.orientation = base.rotation * spin
            } else {
                entity.orientation = base.rotation
            }
            if combined.opacityMultiplier < 0.999 {
                entity.components.set(OpacityComponent(opacity: combined.opacityMultiplier))
            } else if entity.components.has(OpacityComponent.self) {
                entity.components.remove(OpacityComponent.self)
            }
        }
    }

    public func applyActiveMotions(stepElapsed: TimeInterval, totalElapsed: TimeInterval) {
        applySequenceAnimationTracks()
        applyActiveBehaviors()
        guard !activeMotions.isEmpty else { return }
        let absoluteTime = Float(totalElapsed)
        let authoredNow = animationClock?()
        for (action, startedAt) in activeMotions.values {
            guard let entity = entityRegistry[action.entity], entity.isEnabled else { continue }
            // Measured from the MOTION's own start on the authored clock — the
            // same rule `ScrubCompositor` uses, so the editor and the headset
            // draw the same frame. Falls back to the legacy step-relative
            // measure only when no authored clock was available.
            let progress: Float
            if let startedAt, let authoredNow {
                progress = MotionProgress.progress(startTime: startedAt,
                                                   now: authoredNow,
                                                   duration: action.duration)
            } else {
                progress = MotionProgress.progress(startTime: 0,
                                                   now: stepElapsed,
                                                   duration: action.duration)
            }

            if let positionCurve = action.position {
                entity.position = MotionCurveEvaluator.evaluate(
                    positionCurve, t: progress, absoluteTime: absoluteTime
                )
            }
            if let scaleCurve = action.scale {
                entity.scale = MotionCurveEvaluator.evaluate(
                    scaleCurve, t: progress, absoluteTime: absoluteTime
                )
            }
            if let rotationCurve = action.rotation {
                let axisAngle = MotionCurveEvaluator.evaluate(
                    rotationCurve, t: progress, absoluteTime: absoluteTime
                )
                let angle = simd_length(axisAngle)
                if angle > 0 {
                    entity.orientation = simd_quatf(angle: angle, axis: axisAngle / angle)
                } else {
                    entity.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                }
            }
        }
    }

    /// Sample every sequence track at the authored sequence time and write the
    /// poses. Runs even for disabled entities so a reveal mid-curve finds
    /// the entity already in the right pose. Opacity is only driven when the
    /// track keys it — otherwise the step/action system owns visibility.
    /// EXPLORE LOOP OVERLAY, by authored entity id.
    ///
    /// Set only for the few entities an author explicitly marked "Loop During
    /// Explore", and only while the story is held at a region boundary. The
    /// ordinary Sequence clock stays PARKED at that boundary — this replaces
    /// the sample time for these entities alone. It moves no key, rewrites no
    /// track and creates no second animation system; when the region resolves
    /// the override is removed and evaluation returns to normal.
    public var animationLoopOverrides: [String: Double] = [:]

    private func applySequenceAnimationTracks() {
        guard !sequenceAnimationTracks.isEmpty, let clock = animationClock else { return }
        let time = clock()
        for track in sequenceAnimationTracks {
            guard let entity = entityRegistry[track.entity] else { continue }
            // The overlay wins for this entity, if one is installed.
            let time = animationLoopOverrides[track.entity] ?? time
            let rest = restTransformData(for: track.entity, entity: entity)
            let pose = SequenceAnimationEvaluator.samplePose(track, at: time, rest: rest)
            entity.position = SIMD3(pose.position.x, pose.position.y, pose.position.z)
            entity.orientation = simd_quatf(
                vector: SIMD4(pose.rotation.x, pose.rotation.y, pose.rotation.z, pose.rotation.w)
            )
            entity.scale = SIMD3(pose.scale.x, pose.scale.y, pose.scale.z)
            if let opacity = pose.opacity {
                entity.components.set(OpacityComponent(opacity: opacity))
            }
        }
    }

    /// The entity's rest pose for unkeyed channels: its registration-time
    /// transform (the document's base transform).
    private func restTransformData(for name: String, entity: Entity) -> TransformData {
        let t = originalTransforms[name] ?? entity.transform
        return TransformData(
            position: Vec3(t.translation.x, t.translation.y, t.translation.z),
            rotation: Quat(
                x: t.rotation.vector.x, y: t.rotation.vector.y,
                z: t.rotation.vector.z, w: t.rotation.vector.w
            ),
            scale: Vec3(t.scale.x, t.scale.y, t.scale.z)
        )
    }

    // MARK: - Entity Persistence

    public func persistEntity(named name: String) {
        persistedEntityNames.insert(name)
        logger.info("Persist entity: \(name)")
    }

    public func unpersistEntity(named name: String) {
        persistedEntityNames.remove(name)
        logger.info("Unpersist entity: \(name)")
    }

    public func enableGesture(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("enableGesture: '\(name)' not found in registry")
            return
        }
        if entity.components[InputTargetComponent.self] == nil {
            entity.components.set(InputTargetComponent())
        }
        if entity.components[HoverEffectComponent.self] == nil {
            entity.components.set(HoverEffectComponent(
                .spotlight(HoverEffectComponent.SpotlightHoverEffectStyle(
                    strength: 2.3
                ))
            ))
        }
        logger.debug("Enabled gesture: \(name)")
    }

    public func disableGesture(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("disableGesture: '\(name)' not found in registry")
            return
        }
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(HoverEffectComponent.self)
        logger.debug("Disabled gesture: \(name)")
    }
}
