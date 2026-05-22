//
//  EntityActionExecutor.swift
//  SharedVisions
//
//  Handles entity show/hide/move/scale/fade/reveal/gesture/persist actions from ChapterEngine.
//  Wraps RealityKit Entity manipulation.
//

import RealityKit
import OSLog

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
    func clearAllMotions()
    func applyActiveMotions(stepElapsed: TimeInterval, totalElapsed: TimeInterval)
}

// MARK: - Implementation

@MainActor
public final class EntityActionExecutor: EntityActionExecutorProtocol {


    public init() {}
    /// Registry of named entities. Populated by ImmersiveView during setup.
    public var entityRegistry: [String: Entity] = [:]

    /// Original transforms for reset support.
    private var originalTransforms: [String: Transform] = [:]

    /// Names of entities that should survive chapter transitions.
    /// Populated by `.persistEntity` step actions; respected by `resetAllEntities()`.
    public var persistedEntityNames: Set<String> = []

    /// Per-entity active motion curves. Populated by `.animateMotion` step actions
    /// when a step starts; cleared at every step boundary by `clearAllMotions()`.
    /// `applyActiveMotions(stepElapsed:totalElapsed:)` samples each entry per frame
    /// and writes the result back to the entity's transform.
    private var activeMotions: [String: AnimateMotionAction] = [:]

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

    /// Register an entity with a name for the chapter engine to reference.
    public func register(_ entity: Entity, name: String) {
        entityRegistry[name] = entity
        originalTransforms[name] = entity.transform
    }

    /// Drop a registered entity name. Called by `DocumentEntityLoader.unload`
    /// when the loaded document changes (live hot-reload, project switch),
    /// so old chapter actions referencing a stale name fail safely instead
    /// of operating on the deleted Entity.
    public func unregister(name: String) {
        entityRegistry.removeValue(forKey: name)
        originalTransforms.removeValue(forKey: name)
    }

    public func showEntity(named name: String) {
        guard let entity = entityRegistry[name] else {
            logger.warning("showEntity: '\(name)' not found in registry")
            return
        }
        entity.isEnabled = true
        logger.debug("Show entity: \(name)")
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
            let targetRotation = entity.orientation(relativeTo: nil)

            if let multiplier = action.scaleMultiplier {
                targetScale *= multiplier
            }
            if let absolute = action.absoluteScale {
                targetScale = absolute
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
            let targetRotation = entity.orientation

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

        logger.debug("Reveal entity: \(action.entity) fadeIn=\(String(format: "%.1f", action.fadeIn))s")
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
            // Return to the canonical "default" state — hidden until a chapter action reveals it.
            entity.isEnabled = false
        }
        logger.info("Reset all entity transforms and disabled non-persisted entities")
    }

    // MARK: - Active motion

    public func beginMotion(_ action: AnimateMotionAction) {
        guard entityRegistry[action.entity] != nil else {
            logger.warning("beginMotion: entity '\(action.entity)' not found in registry")
            return
        }
        activeMotions[action.entity] = action
        logger.debug("beginMotion: \(action.entity) (duration \(action.duration)s)")
    }

    public func clearAllMotions() {
        if !activeMotions.isEmpty {
            logger.debug("Cleared \(self.activeMotions.count) active motion(s)")
        }
        activeMotions.removeAll(keepingCapacity: true)
    }

    public func applyActiveMotions(stepElapsed: TimeInterval, totalElapsed: TimeInterval) {
        guard !activeMotions.isEmpty else { return }
        let absoluteTime = Float(totalElapsed)
        for action in activeMotions.values {
            guard let entity = entityRegistry[action.entity], entity.isEnabled else { continue }
            let progress = Float(max(0, min(1, stepElapsed / max(action.duration, 0.001))))

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
