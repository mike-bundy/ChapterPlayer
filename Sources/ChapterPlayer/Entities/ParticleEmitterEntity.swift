//
//  ParticleEmitterEntity.swift
//  ChapterPlayer
//
//  Real particle rendering for `.particles`-kind entities. An entity
//  definition carries only a `particlePresetId`; the document's
//  `particlePresets` array holds the 14-field `ParticleEmitterPreset`
//  (ChapterScript) that the editors author. This file maps that format
//  preset onto RealityKit's `ParticleEmitterComponent` the same way
//  Maestro's Afterburn viewport does (`ParticleEmitterComponent.create(from:)`
//  on the Mac), so authored values look the same in the player.
//
//  Non-looping presets use the Mac's "Impact" semantics: the emitter is
//  built idle (`isEmitting = false`) with a `burstCount` sized to one
//  lifespan's worth of particles (`birthRate * lifeSpan` — exactly how the
//  Mac's Impact preset derives its 500), and `EntityActionExecutor` fires
//  `burst()` when the entity is shown/revealed. Re-revealing re-bursts.
//

import Foundation
import OSLog
import RealityKit
import UIKit
import ChapterScript

private let particleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "Particles"
)

/// Marker on `.particles` entities built from a non-looping preset:
/// show/reveal should fire a one-shot `ParticleEmitterComponent.burst()`
/// instead of relying on continuous emission.
public struct ParticleBurstOnRevealComponent: Component {
    public init() {}
}

extension EntityFactory {

    /// Build a `.particles` entity by resolving its bound preset id against
    /// `particlePresets` (populated from `ChapterDocument.particlePresets`
    /// on every `DocumentEntityLoader.materialize`). Missing bindings still
    /// return a bare transform anchor so the entity keeps its place in the
    /// scene graph and picks up the emitter on the next re-materialization
    /// (e.g. a live-sync upsert of the preset).
    func makeParticleEmitter(_ def: EntityDefinition) -> Entity {
        let entity = Entity()
        guard let presetId = def.particlePresetId else {
            particleLogger.warning("Particles entity '\(def.id)' has no particlePresetId; rendering nothing")
            return entity
        }
        guard let preset = particlePresets[presetId] else {
            particleLogger.warning("Particles entity '\(def.id)' references unknown preset '\(presetId)'; rendering nothing")
            return entity
        }

        entity.components.set(ParticleEmitterComponent(preset: preset))
        if !preset.loops {
            entity.components.set(ParticleBurstOnRevealComponent())
        }
        return entity
    }
}

extension ParticleEmitterComponent {

    /// Map a ChapterScript `ParticleEmitterPreset` (the 14 format-level
    /// fields) onto a RealityKit emitter. Fields the format doesn't carry
    /// (shape size, birth location/direction, emission direction) use
    /// Afterburn's `EmitterSettings` defaults so the player matches the
    /// Mac viewport's rendering of the same preset.
    init(preset: ParticleEmitterPreset) {
        self.init()

        // Emitter shape. RealityKit has no hemisphere case; a sphere is
        // the nearest faithful stand-in.
        switch preset.emitterShape {
        case .point:      emitterShape = .point
        case .sphere:     emitterShape = .sphere
        case .hemisphere: emitterShape = .sphere
        case .cone:       emitterShape = .cone
        case .plane:      emitterShape = .plane
        case .box:        emitterShape = .box
        }
        // The format carries no shape size — Afterburn's default extents.
        // Authors size the emission region by scaling the entity.
        emitterShapeSize = SIMD3<Float>(repeating: 0.1)
        birthLocation = .surface
        birthDirection = .normal
        emissionDirection = SIMD3<Float>(0, 1, 0)

        speed = preset.speed
        speedVariation = 0
        mainEmitter.birthRate = preset.birthRate
        mainEmitter.lifeSpan = Double(preset.lifeSpan)
        // Format angle is degrees (Maestro's "Spread angle (°)");
        // RealityKit's spreadingAngle is radians.
        mainEmitter.spreadingAngle = preset.spreadAngle * .pi / 180

        // Size: startSize is the birth size; endSize expresses as the
        // end-of-lifespan multiplier. A zero start size can't carry a
        // multiplier, so render at the end size instead of dividing by zero.
        if preset.startSize > 0 {
            mainEmitter.size = preset.startSize
            mainEmitter.sizeMultiplierAtEndOfLifespan = preset.endSize / preset.startSize
        } else {
            mainEmitter.size = max(preset.endSize, 0.001)
            mainEmitter.sizeMultiplierAtEndOfLifespan = 1
        }

        // Color + opacity ramp: the preset's start/end opacities ride the
        // color's alpha channel. The opacity curve stays constant so the
        // fade comes from color evolution alone (no double-fading).
        let startColor = uiColor(preset.color, opacity: preset.startOpacity)
        if abs(preset.startOpacity - preset.endOpacity) < 0.0001 {
            mainEmitter.color = .constant(.single(startColor))
        } else {
            mainEmitter.color = .evolving(
                start: .single(startColor),
                end: .single(uiColor(preset.color, opacity: preset.endOpacity))
            )
        }
        mainEmitter.opacityCurve = .constant

        switch preset.blending {
        case .additive: mainEmitter.blendMode = .additive
        case .alpha:    mainEmitter.blendMode = .alpha
        case .opaque:   mainEmitter.blendMode = .opaque
        }

        mainEmitter.acceleration = SIMD3<Float>(preset.gravity.x, preset.gravity.y, preset.gravity.z)

        if preset.loops {
            isEmitting = true
        } else {
            // Mac "Impact" semantics: idle emitter + one-shot burst
            // (fired by EntityActionExecutor on show/reveal). One
            // lifespan's worth of particles, matching how the Mac's
            // Impact preset derives its burst count.
            isEmitting = false
            burstCount = max(1, min(Int(preset.birthRate * preset.lifeSpan), 10_000))
            burstCountVariation = 0
        }
    }
}

private func uiColor(_ c: ColorRGBA, opacity: Float) -> UIColor {
    UIColor(
        red: CGFloat(c.r),
        green: CGFloat(c.g),
        blue: CGFloat(c.b),
        alpha: CGFloat(c.a * opacity)
    )
}
