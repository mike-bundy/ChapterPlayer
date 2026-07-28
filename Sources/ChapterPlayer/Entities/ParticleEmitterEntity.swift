//
//  ParticleEmitterEntity.swift
//  ChapterPlayer
//
//  Real particle rendering for `.particles`-kind entities. An entity
//  definition carries only a `particlePresetId`; the document's
//  `particlePresets` array holds the full-fidelity `ParticleEmitterPreset`
//  (ChapterScript) that the editors author. This file maps that format
//  preset onto RealityKit's `ParticleEmitterComponent` the same way
//  Maestro's Afterburn viewport does (`ParticleEmitterComponent.create(from:)`
//  on the Mac), so authored values look the same in the player.
//
//  The mapping is a pure function (`ParticleEmitterComponent(preset:)`) so
//  editors can reuse it; only texture loading is async. Particle images
//  ("default" soft sprite or SF Symbol names) resolve through
//  `ParticleTextureCache` and are applied to the entity's component when
//  they land — the emitter renders untextured in the meantime.
//
//  Non-looping presets use the Mac's "Impact" semantics: the emitter is
//  built idle (`isEmitting = false`) with a burst sized from the preset's
//  `burstCount` when supplied, else one lifespan's worth of particles
//  (`birthRate * lifeSpan` — exactly how the Mac's Impact preset derives
//  its 500), and `EntityActionExecutor` fires `burst()` when the entity is
//  shown/revealed. Re-revealing re-bursts.
//

import Foundation
import CoreGraphics
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

        // Textures load async; the emitter runs untextured until they land.
        let mainImage = ParticleTextureCache.normalized(preset.mainImage)
        let spawnImage = ParticleTextureCache.normalized(preset.spawn?.image)
        if mainImage != nil || spawnImage != nil {
            Task { @MainActor in
                let main = await ParticleTextureCache.shared.texture(for: mainImage)
                let spawned = await ParticleTextureCache.shared.texture(for: spawnImage)
                guard var emitter = entity.components[ParticleEmitterComponent.self] else { return }
                if let main { emitter.mainEmitter.image = main }
                if let spawned { emitter.spawnedEmitter?.image = spawned }
                entity.components.set(emitter)
            }
        }
        return entity
    }
}

extension ParticleEmitterComponent {

    /// Map a ChapterScript `ParticleEmitterPreset` (full-fidelity Afterburn
    /// knob set) onto a RealityKit emitter, porting the proven conversions
    /// from Afterburn's `ParticleEmitterComponent.create(from:)` so the
    /// player matches the Mac viewport's rendering of the same preset.
    ///
    /// Pure and synchronous — particle images are applied separately (see
    /// `makeParticleEmitter`) because `TextureResource` creation is async.
    /// Public so editors (MaestroVision's live preset preview) can build
    /// the exact component the player renders.
    public init(preset: ParticleEmitterPreset) {
        self.init()

        // MARK: Emitter shape + birth geometry
        emitterShape = Self.shape(preset.emitterShape)
        emitterShapeSize = SIMD3<Float>(preset.emitterShapeSize)
        birthLocation = Self.birthLocation(preset.birthLocation)
        birthDirection = Self.birthDirection(preset.birthDirection)
        emissionDirection = SIMD3<Float>(preset.emissionDirection)
        radialAmount = preset.radialAmount
        torusInnerRadius = preset.torusInnerRadius

        // MARK: Speed + spread
        speed = preset.speed
        speedVariation = 0
        mainEmitter.birthRate = preset.birthRate
        mainEmitter.birthRateVariation = preset.birthRateVariation
        mainEmitter.lifeSpan = Double(preset.lifeSpan)
        mainEmitter.lifeSpanVariation = Double(preset.lifeSpanVariation)
        // Format spreadAngle is degrees (Maestro's "Spread angle (°)");
        // RealityKit's spreadingAngle is radians.
        mainEmitter.spreadingAngle = preset.spreadAngle * .pi / 180

        // MARK: Size
        // startSize is the birth size; endSize expresses as the
        // end-of-lifespan multiplier. A zero start size can't carry a
        // multiplier, so render at the end size instead of dividing by zero.
        if preset.startSize > 0 {
            mainEmitter.size = preset.startSize
            mainEmitter.sizeMultiplierAtEndOfLifespan = preset.endSize / preset.startSize
        } else {
            mainEmitter.size = max(preset.endSize, 0.001)
            mainEmitter.sizeMultiplierAtEndOfLifespan = 1
        }
        mainEmitter.sizeVariation = preset.sizeVariation
        mainEmitter.sizeMultiplierAtEndOfLifespanPower = preset.sizeMultiplierAtEndOfLifespanPower

        // MARK: Physics
        // gravity is the format name for the constant acceleration vector.
        mainEmitter.mass = preset.mass
        mainEmitter.massVariation = preset.massVariation
        mainEmitter.acceleration = SIMD3<Float>(preset.gravity)
        mainEmitter.dampingFactor = preset.dampingFactor
        mainEmitter.stretchFactor = preset.stretchFactor
        // angle/angularSpeed are radians passed straight through — matching
        // what Afterburn's viewport renders (its create(from:) does no
        // conversion).
        mainEmitter.angle = preset.angle
        mainEmitter.angleVariation = preset.angleVariation
        mainEmitter.angularSpeed = preset.angularSpeed
        mainEmitter.angularSpeedVariation = preset.angularSpeedVariation

        // MARK: Color + opacity
        mainEmitter.color = Self.color(
            preset.colorSetting,
            color: preset.color,
            color2: preset.color2,
            startOpacity: preset.startOpacity,
            endOpacity: preset.endOpacity
        )
        mainEmitter.colorEvolutionPower = preset.colorEvolutionPower
        mainEmitter.opacityCurve = Self.opacityCurve(preset.opacityCurve)
        mainEmitter.blendMode = Self.blendMode(preset.blending)
        mainEmitter.billboardMode = Self.billboardMode(preset.billboardMode)
        mainEmitter.isLightingEnabled = preset.isLightingEnabled
        mainEmitter.sortOrder = Self.sortOrder(preset.sortOrder)

        // MARK: Force fields
        mainEmitter.noiseStrength = preset.noiseStrength
        mainEmitter.noiseScale = preset.noiseScale
        mainEmitter.noiseAnimationSpeed = preset.noiseAnimationSpeed
        mainEmitter.attractionStrength = preset.attractionStrength
        mainEmitter.attractionCenter = SIMD3<Float>(preset.attractionCenter)
        mainEmitter.vortexStrength = preset.vortexStrength
        mainEmitter.vortexDirection = SIMD3<Float>(preset.vortexDirection)

        // MARK: Simulation
        particlesInheritTransform = preset.particlesInheritTransform

        // MARK: Spawned (secondary) emitter
        if let spec = preset.spawn {
            spawnOccasion = Self.spawnOccasion(spec.spawnOccasion)
            spawnSpreadFactor = spec.spawnSpreadFactor
            spawnVelocityFactor = spec.spawnVelocityFactor
            spawnInheritsParentColor = spec.spawnInheritsParentColor

            var spawned = ParticleEmitterComponent.ParticleEmitter()
            spawned.birthRate = spec.birthRate
            spawned.birthRateVariation = spec.birthRateVariation
            spawned.lifeSpan = Double(spec.lifeSpan)
            spawned.lifeSpanVariation = Double(spec.lifeSpanVariation)
            spawned.size = spec.size
            spawned.sizeVariation = spec.sizeVariation
            spawned.sizeMultiplierAtEndOfLifespan = spec.sizeMultiplierAtEndOfLifespan
            spawned.sizeMultiplierAtEndOfLifespanPower = spec.sizeMultiplierAtEndOfLifespanPower
            spawned.mass = spec.mass
            spawned.massVariation = spec.massVariation
            spawned.acceleration = SIMD3<Float>(spec.acceleration)
            spawned.dampingFactor = spec.dampingFactor
            spawned.spreadingAngle = spec.spreadAngle * .pi / 180
            spawned.stretchFactor = spec.stretchFactor
            spawned.angle = spec.angle
            spawned.angleVariation = spec.angleVariation
            spawned.angularSpeed = spec.angularSpeed
            spawned.angularSpeedVariation = spec.angularSpeedVariation
            // The spawned spec carries its own full opacity ramp semantics
            // through opacityCurve; its color modes use full alpha bounds.
            spawned.color = Self.color(
                spec.colorSetting,
                color: spec.color,
                color2: spec.color2,
                startOpacity: 1,
                endOpacity: 1
            )
            spawned.colorEvolutionPower = spec.colorEvolutionPower
            spawned.opacityCurve = Self.opacityCurve(spec.opacityCurve)
            spawned.blendMode = Self.blendMode(spec.blending)
            spawned.billboardMode = Self.billboardMode(spec.billboardMode)
            spawned.isLightingEnabled = spec.isLightingEnabled
            spawned.sortOrder = Self.sortOrder(spec.sortOrder)
            spawned.noiseStrength = spec.noiseStrength
            spawned.noiseScale = spec.noiseScale
            spawned.noiseAnimationSpeed = spec.noiseAnimationSpeed
            spawned.attractionStrength = spec.attractionStrength
            spawned.attractionCenter = SIMD3<Float>(spec.attractionCenter)
            spawned.vortexStrength = spec.vortexStrength
            spawned.vortexDirection = SIMD3<Float>(spec.vortexDirection)
            spawnedEmitter = spawned
        }

        // MARK: Looping / burst
        if preset.loops {
            isEmitting = true
            // A format-supplied burstCount still applies so explicit burst()
            // calls on looping emitters honor the authored size.
            if let count = preset.burstCount {
                burstCount = max(1, count)
                burstCountVariation = 0
            }
        } else {
            // Mac "Impact" semantics: idle emitter + one-shot burst
            // (fired by EntityActionExecutor on show/reveal). Sized from
            // the preset when authored, else one lifespan's worth of
            // particles — matching how the Mac's Impact preset derives
            // its burst count.
            isEmitting = false
            burstCount = preset.burstCount.map { max(1, $0) }
                ?? max(1, min(Int(preset.birthRate * preset.lifeSpan), 10_000))
            burstCountVariation = 0
        }
    }

    // MARK: - Enum mappings (ported from Afterburn's create(from:))

    private static func shape(_ shape: ParticleEmitterShape) -> ParticleEmitterComponent.EmitterShape {
        switch shape {
        case .point:      return .point
        case .sphere:     return .sphere
        // RealityKit has no hemisphere case; a sphere is the nearest
        // faithful stand-in (matches the pre-expansion player).
        case .hemisphere: return .sphere
        case .cone:       return .cone
        case .plane:      return .plane
        case .box:        return .box
        case .cylinder:   return .cylinder
        case .torus:      return .torus
        }
    }

    private static func birthLocation(_ location: ParticleBirthLocation) -> ParticleEmitterComponent.BirthLocation {
        switch location {
        case .surface: return .surface
        case .volume:  return .volume
        // vertices requires a count parameter RealityKit doesn't expose
        // here; surface is Afterburn's viewport fallback too.
        case .vertices: return .surface
        }
    }

    private static func birthDirection(_ direction: ParticleBirthDirection) -> ParticleEmitterComponent.BirthDirection {
        switch direction {
        case .normal: return .normal
        case .world:  return .world
        case .local:  return .local
        }
    }

    private static func color(
        _ mode: ParticleColorMode,
        color: ColorRGBA,
        color2: ColorRGBA,
        startOpacity: Float,
        endOpacity: Float
    ) -> ParticleEmitterComponent.ParticleEmitter.ParticleColor {
        switch mode {
        case .constant:
            // Legacy rendering: single color whose alpha rides the
            // start/end opacity ramp (constant when the two agree).
            let start = uiColor(color, opacity: startOpacity)
            if abs(startOpacity - endOpacity) < 0.0001 {
                return .constant(.single(start))
            }
            return .evolving(
                start: .single(start),
                end: .single(uiColor(color, opacity: endOpacity))
            )
        case .random, .evolving:
            // Afterburn renders .random as evolving (random isn't
            // available in its viewport); match it for identical output.
            return .evolving(
                start: .single(uiColor(color, opacity: startOpacity)),
                end: .single(uiColor(color2, opacity: endOpacity))
            )
        }
    }

    private static func opacityCurve(_ curve: ParticleOpacityCurve) -> ParticleEmitterComponent.ParticleEmitter.OpacityCurve {
        switch curve {
        case .constant:                 return .constant
        case .fadeIn, .linearFadeIn:    return .linearFadeIn
        case .fadeOut, .linearFadeOut:  return .linearFadeOut
        // visionOS has no linear in-out; gradualFadeInOut is the closest.
        // (Afterburn's Mac viewport falls back to constant here — the
        // platform simply lacks any in-out curve on macOS.)
        case .fadeInOut:                return .gradualFadeInOut
        }
    }

    private static func billboardMode(_ mode: ParticleBillboardMode) -> ParticleEmitterComponent.ParticleEmitter.BillboardMode {
        switch mode {
        case .billboard:         return .billboard
        case .billboardYAligned: return .billboardYAligned
        // freeRotating / velocityAligned aren't in RealityKit's surface;
        // Afterburn's viewport falls back to billboard — match it.
        case .freeRotating:      return .billboard
        case .velocityAligned:   return .billboard
        }
    }

    private static func blendMode(_ blending: MaterialBlending) -> ParticleEmitterComponent.ParticleEmitter.BlendMode {
        switch blending {
        case .additive: return .additive
        case .alpha:    return .alpha
        case .opaque:   return .opaque
        }
    }

    private static func sortOrder(_ order: ParticleSortOrder) -> ParticleEmitterComponent.ParticleEmitter.SortOrder {
        switch order {
        case .unsorted:        return .unsorted
        case .depthAscending:  return .increasingDepth
        case .depthDescending: return .decreasingDepth
        case .ageAscending:    return .increasingAge
        case .ageDescending:   return .decreasingAge
        }
    }

    private static func spawnOccasion(_ occasion: ParticleSpawnOccasion) -> ParticleEmitterComponent.SpawnOccasion {
        switch occasion {
        case .onBirth:  return .onBirth
        case .onDeath:  return .onDeath
        case .onUpdate: return .onUpdate
        }
    }
}

// MARK: - Texture cache for particle images

/// Renders and caches particle sprite textures: `"default"` = the soft
/// radial-gradient sprite Afterburn ships, anything else = an SF Symbol
/// rendered white at 128×128 (tintable by the emitter's particle color).
/// Ported from Afterburn's `ParticleTextureCache` actor. Public so editor
/// hosts (MaestroVision) can resolve the same sprites for live previews.
public actor ParticleTextureCache {
    public static let shared = ParticleTextureCache()

    private var cache: [String: TextureResource] = [:]

    /// Collapse the format's "no image" spellings (`nil` / `"none"` / empty)
    /// to `nil` so callers can skip the load entirely.
    public static func normalized(_ imageName: String??) -> String? {
        guard let name = imageName ?? nil, !name.isEmpty, name != "none" else { return nil }
        return name
    }

    public func texture(for imageName: String?) async -> TextureResource? {
        guard let imageName else { return nil }
        if let cached = cache[imageName] {
            return cached
        }
        guard let texture = await generateTexture(for: imageName) else {
            particleLogger.warning("Failed to build particle texture for image '\(imageName)'")
            return nil
        }
        cache[imageName] = texture
        return texture
    }

    private func generateTexture(for imageName: String) async -> TextureResource? {
        let size = CGSize(width: 128, height: 128)
        let image: UIImage
        if imageName == "default" {
            image = Self.defaultParticleImage(size: size)
        } else {
            let config = UIImage.SymbolConfiguration(pointSize: 100, weight: .regular)
            guard let sfImage = UIImage(systemName: imageName, withConfiguration: config) else {
                return nil
            }
            // Render the symbol white, centered, aspect-preserving.
            let renderer = UIGraphicsImageRenderer(size: size)
            image = renderer.image { _ in
                let symbolSize = sfImage.size
                let scale = min(size.width / symbolSize.width, size.height / symbolSize.height) * 0.9
                let rect = CGRect(
                    x: (size.width - symbolSize.width * scale) / 2,
                    y: (size.height - symbolSize.height * scale) / 2,
                    width: symbolSize.width * scale,
                    height: symbolSize.height * scale
                )
                sfImage.withTintColor(.white, renderingMode: .alwaysTemplate).draw(in: rect)
            }
        }

        guard let cgImage = image.cgImage else { return nil }
        do {
            return try await TextureResource(image: cgImage, options: .init(semantic: .color))
        } catch {
            particleLogger.warning("TextureResource creation failed for '\(imageName)': \(error)")
            return nil
        }
    }

    /// Soft radial-gradient circle — the classic "glow puff" sprite.
    private static func defaultParticleImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let colors = [
                UIColor.white.cgColor,
                UIColor.white.withAlphaComponent(0.5).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.5, 1]
            ) {
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: radius,
                    options: []
                )
            }
        }
    }
}

// MARK: - Helpers

// SIMD3<Float>(Vec3) conversion comes from ChapterScript+Runtime.swift.

private func uiColor(_ c: ColorRGBA, opacity: Float) -> UIColor {
    UIColor(
        red: CGFloat(c.r),
        green: CGFloat(c.g),
        blue: CGFloat(c.b),
        alpha: CGFloat(c.a * opacity)
    )
}
