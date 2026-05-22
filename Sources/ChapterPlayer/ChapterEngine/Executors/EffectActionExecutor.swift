//
//  EffectActionExecutor.swift
//  SharedVisions
//
//  Slim effect executor for SharedVisions. Implements the example VFX
//  (PulseRing, SparkBurst) and provides a `handleCustomAction(id:)` escape hatch
//  for chapter authors. Extend this executor with new effect types as content grows.
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
    public weak var sceneRoot: Entity?

    public private(set) var pulseRingEntity: PulseRingEntity?
    public private(set) var sparkBurstEntity: SparkBurstEntity?

    // MARK: - Pulse Ring

    public func showPulseRing(config: PulseRingConfig) {
        let existing = pulseRingEntity
        let entity = existing ?? PulseRingEntity()
        entity.configure(config)
        entity.isEnabled = true
        if existing == nil {
            sceneRoot?.addChild(entity)
            pulseRingEntity = entity
        }
        logger.info("showPulseRing — \(config.ringCount) discs at radius \(config.radius)m")
    }

    public func hidePulseRing() {
        pulseRingEntity?.isEnabled = false
        logger.info("hidePulseRing")
    }

    // MARK: - Spark Burst

    public func startSparkBurst(config: SparkBurstConfig) {
        let existing = sparkBurstEntity
        let entity = existing ?? SparkBurstEntity()
        entity.configure(config)
        entity.isEnabled = true
        if existing == nil {
            sceneRoot?.addChild(entity)
            sparkBurstEntity = entity
        }
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

    public func handleCustomAction(id: String) {
        logger.info("handleCustomAction — id=\(id) (no handler registered)")
    }
}
