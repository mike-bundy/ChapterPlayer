//
//  EffectActionExecutor.swift
//  SharedVisions
//
//  Slim effect executor for SharedVisions. Implements the example VFX
//  (PulseRing, SparkBurst) and provides a `handleCustomAction(id:)` escape hatch
//  for sequence authors. Extend this executor with new effect types as content grows.
//

import RealityKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "EffectActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol EffectActionExecutorProtocol {
    // Pulse Ring — persistent ambient VFX
    func showPulseRing(config: PulseRingConfig)
    func hidePulseRing()

    // Spark Burst — one-shot ephemeral VFX
    func startSparkBurst(config: SparkBurstConfig)
    func stopSparkBurst()

    // Lifecycle
    func pauseAll()
    func resumeAll()
    func resetAllEffects()

    // Escape hatch
    func handleCustomAction(id: String)
}

// MARK: - Implementation

@MainActor
public final class EffectActionExecutor: EffectActionExecutorProtocol {


    public init() {}
    /// Root entity that owns all effect entities. Wired by ImmersiveView at setup.
    ///
    /// WEAK, AND RE-WIRED ON EVERY IMMERSIVE MOUNT — which is exactly why the
    /// effect entities below cannot be parented once and cached forever.
    public weak var sceneRoot: Entity? {
        didSet {
            guard oldValue !== sceneRoot else { return }
            // THE ROOT WENT AWAY OR CHANGED. Detach what we own from the old
            // one rather than leaving it stranded there: the old subtree may
            // outlive the mount, and an enabled effect under a dead root is a
            // running animation nobody can see and nobody can stop.
            //
            // The entities are KEPT — they are ours, they are cheap, and they
            // re-attach on the next show. What must not survive is the
            // PARENTING, because that is the thing that says which scene they
            // belong to.
            for entity in [pulseRingEntity as Entity?, sparkBurstEntity as Entity?] {
                guard let entity, entity.parent !== sceneRoot else { continue }
                entity.isEnabled = false
                entity.removeFromParent()
            }
        }
    }

    /// AN EFFECT ENTITY BELONGS TO THE ROOT THAT IS CURRENT WHEN IT IS SHOWN.
    ///
    /// This used to be `if existing == nil { sceneRoot?.addChild(entity) }` —
    /// parented on FIRST show and never again. Two ways that failed, both
    /// silent and both permanent for the rest of the session:
    ///
    ///   • the immersive space remounts, `sceneRoot` becomes a different
    ///     entity, and the cached effect stays a child of the old (dead) root —
    ///     `isEnabled = true` then enables something that is not in any scene,
    ///     so the effect simply never appears again;
    ///   • the very first show happens before the root is wired, so
    ///     `sceneRoot?.addChild` no-ops — and because the entity was cached
    ///     anyway, `existing == nil` is false ever after and it never recovers.
    ///
    /// Re-parenting is idempotent: `addChild` on the entity's current parent is
    /// a no-op, so the steady state costs an identity comparison.
    private func attachToCurrentRoot(_ entity: Entity, what: String) {
        guard let root = sceneRoot else {
            logger.warning("\(what) has no scene root to attach to — it will attach on the next show")
            entity.removeFromParent()
            return
        }
        guard entity.parent !== root else { return }
        entity.removeFromParent()
        root.addChild(entity)
    }

    public private(set) var pulseRingEntity: PulseRingEntity?
    public private(set) var sparkBurstEntity: SparkBurstEntity?

    /// id → handler closure for `.custom(id:)` step actions. Consumers
    /// register handlers at app launch; the engine looks them up here
    /// when a sequence step fires `.custom(id:)`.
    private var customHandlers: [String: @MainActor () -> Void] = [:]

    // MARK: - Pulse Ring

    public func showPulseRing(config: PulseRingConfig) {
        let entity = pulseRingEntity ?? PulseRingEntity()
        entity.configure(config)
        entity.isEnabled = true
        attachToCurrentRoot(entity, what: "pulse ring")
        pulseRingEntity = entity
        logger.info("showPulseRing — \(config.ringCount) discs at radius \(config.radius)m")
    }

    public func hidePulseRing() {
        pulseRingEntity?.isEnabled = false
        logger.info("hidePulseRing")
    }

    // MARK: - Spark Burst

    public func startSparkBurst(config: SparkBurstConfig) {
        let entity = sparkBurstEntity ?? SparkBurstEntity()
        entity.configure(config)
        entity.isEnabled = true
        attachToCurrentRoot(entity, what: "spark burst")
        sparkBurstEntity = entity
        entity.trigger(duration: config.duration)
        logger.info("startSparkBurst — duration \(config.duration)s at \(String(describing: config.position))")
    }

    public func stopSparkBurst() {
        sparkBurstEntity?.stop()
        logger.info("stopSparkBurst")
    }

    // MARK: - Lifecycle

    public func pauseAll() {
        pulseRingEntity?.setPaused(true)
        sparkBurstEntity?.setPaused(true)
    }

    public func resumeAll() {
        pulseRingEntity?.setPaused(false)
        sparkBurstEntity?.setPaused(false)
    }

    public func resetAllEffects() {
        pulseRingEntity?.isEnabled = false
        sparkBurstEntity?.stop()
        sparkBurstEntity?.isEnabled = false
        logger.info("resetAllEffects")
    }

    // MARK: - Custom

    /// Register a handler that fires when a sequence step's `.custom(id:)`
    /// action runs. Overwrites any previous handler for the same id.
    public func registerCustomAction(id: String, _ handler: @escaping @MainActor () -> Void) {
        customHandlers[id] = handler
    }

    /// Remove a previously-registered custom action handler. Calls with
    /// an unknown id are no-ops.
    public func unregisterCustomAction(id: String) {
        customHandlers.removeValue(forKey: id)
    }

    public func handleCustomAction(id: String) {
        if let handler = customHandlers[id] {
            handler()
        } else {
            logger.info("handleCustomAction — id=\(id) (no handler registered)")
        }
    }
}
