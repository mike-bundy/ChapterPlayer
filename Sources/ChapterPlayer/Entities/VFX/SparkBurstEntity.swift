//
//  SparkBurstEntity.swift
//  SharedVisions
//
//  Example VFX #2 — a one-shot upward firework burst from a point.
//
//  Archetype: ephemeral, directional, eye-catching accent.
//  Re-skinned from the HSBC stream-particles pattern (which was a horizontal stream
//  of instanced cubes with a red→green gradient). This uses native RealityKit
//  `ParticleEmitterComponent` with a spherical radial-outward emission — different
//  tech, different shape, different duration profile.
//

import RealityKit
import Foundation
import simd
import SwiftUI

@MainActor
public final class SparkBurstEntity: Entity {

    private var emitter: Entity?
    private var stopTask: Task<Void, Never>?
    private var isPausedFlag = false
    private var config: SparkBurstConfig = SparkBurstConfig()

    // MARK: - Configuration

    public func configure(_ config: SparkBurstConfig) {
        self.config = config
        self.position = config.position

        let existing = emitter
        let e = existing ?? Entity()
        e.name = "sparkBurstEmitter"

        var particles = ParticleEmitterComponent()
        particles.emitterShape = .sphere
        particles.emitterShapeSize = SIMD3<Float>(repeating: config.burstRadius)
        particles.birthLocation = .volume
        particles.birthDirection = .normal   // Radial outward from sphere center
        particles.speed = 0.8

        particles.mainEmitter.birthRate = config.particleBirthRate
        particles.mainEmitter.lifeSpan = Double(config.particleLifeSpan)
        particles.mainEmitter.size = config.particleSize
        particles.mainEmitter.sizeVariation = config.particleSize * 0.5
        particles.mainEmitter.blendMode = .additive
        particles.mainEmitter.opacityCurve = .quickFadeInOut
        particles.mainEmitter.acceleration = SIMD3<Float>(0, 0.8, 0)  // Slight upward drift

        let tint = SwiftUI.Color(
            red: Double(config.tintRed),
            green: Double(config.tintGreen),
            blue: Double(config.tintBlue)
        )
        particles.mainEmitter.color = .evolving(
            start: .single(.init(tint)),
            end: .single(.init(tint.opacity(0)))
        )

        particles.isEmitting = false  // Idle by default; `trigger` turns it on.
        e.components.set(particles)

        if existing == nil {
            addChild(e)
            emitter = e
        }
    }

    // MARK: - Control

    /// Ramps the emitter on for `duration`, then turns it off (particles still fade out via lifeSpan).
    public func trigger(duration: TimeInterval) {
        stopTask?.cancel()
        guard let emitter else { return }
        if var particles = emitter.components[ParticleEmitterComponent.self] {
            particles.isEmitting = true
            emitter.components[ParticleEmitterComponent.self] = particles
        }
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    public func stop() {
        stopTask?.cancel()
        stopTask = nil
        guard let emitter else { return }
        if var particles = emitter.components[ParticleEmitterComponent.self] {
            particles.isEmitting = false
            emitter.components[ParticleEmitterComponent.self] = particles
        }
    }

    public func setPaused(_ paused: Bool) {
        self.isPausedFlag = paused
        guard let emitter else { return }
        if var particles = emitter.components[ParticleEmitterComponent.self] {
            // Pause suppresses emission; previous state resumes on un-pause if trigger is still active.
            particles.isEmitting = !paused && stopTask != nil
            emitter.components[ParticleEmitterComponent.self] = particles
        }
    }

    // MARK: - Lifecycle

    required init() {
        super.init()
        self.name = "SparkBurst"
    }
}

