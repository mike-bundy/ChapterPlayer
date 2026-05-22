//
//  EntityFactory.swift
//  SharedVisionsBuilds RealityKit `Entity` instances from `ChapterScript.EntityDefinition` records.
//  Two routes:
//
//   1. **Built-in kinds** (`.primitive`, `.usdz`, `.text3D`, `.light`, `.videoPanel`)
//      construct entities directly from the spec. These are pure data — anything
//      an experience editor can author lives here.
//
//   2. **`.custom` kind** dispatches to a registered factory closure looked up by
//      `customFactoryId`. This is the escape hatch for entities too procedural
//      to express declaratively (e.g., the existing PulseRing and SparkBurst VFX).
//
//  ImmersiveView still pre-registers the four rich SharedVisions primitives via
//  `PrimitiveEntities.create*()` because they include hand-tuned per-primitive
//  particle systems beyond what `EntityDefinition` currently expresses.
//  When the editor learns to author particle presets (Phase 3+ via Maestro's
//  Afterburn → ParticleEmitterPreset migration), those primitives migrate into
//  `EntityDefinition`-backed builds.
//

import Foundation
import RealityKit
import UIKit
import simd
import ChapterScript

@MainActor
public final class EntityFactory {

    public init() {}

    /// `customFactoryId` → factory closure. Populate at app launch with whatever
    /// custom procedural entities the player supports.
    public private(set) var customFactories: [String: (EntityDefinition) -> Entity] = [:]

    /// Register a factory for `customFactoryId`. The closure receives the
    /// EntityDefinition so factories may consult `customParameters`.
    public func registerCustom(id: String, _ make: @escaping (EntityDefinition) -> Entity) {
        customFactories[id] = make
    }

    /// Build a runtime `Entity` from an `EntityDefinition`. Returns `nil` if the
    /// definition references a custom factory that hasn't been registered.
    public func build(_ definition: EntityDefinition) -> Entity? {
        let entity: Entity
        switch definition.kind {
        case .primitive:
            entity = makePrimitive(definition)
        case .usdz:
            // USDZ loading happens asynchronously via `Entity(named:in:)` —
            // experiences that ship USDZ assets are a Phase 3+ concern.
            entity = Entity()
        case .text3D:
            entity = makeTextEntity(definition)
        case .light:
            entity = makeLightEntity(definition)
        case .videoPanel:
            entity = makeVideoPanel(definition)
        case .particles:
            entity = Entity() // ParticleEmitterPreset binding is Phase 3+
        case .custom:
            guard let id = definition.customFactoryId,
                  let make = customFactories[id]
            else { return nil }
            entity = make(definition)
        }

        entity.name = definition.id
        applyTransform(definition.transform, to: entity)
        entity.isEnabled = definition.initiallyEnabled
        return entity
    }

    // MARK: - Built-in builders

    private func makePrimitive(_ def: EntityDefinition) -> Entity {
        guard let spec = def.primitive else {
            return Entity()
        }
        let mesh = makeMesh(spec)
        let material = makeMaterial(spec.material)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func makeMesh(_ spec: PrimitiveSpec) -> MeshResource {
        switch spec.shape {
        case .sphere:
            return MeshResource.generateSphere(radius: spec.size.x)
        case .box:
            // Treat size as full extents; fall back to size.x if a uniform value is desired.
            return MeshResource.generateBox(size: SIMD3<Float>(spec.size.x, spec.size.y, spec.size.z))
        case .cylinder:
            return MeshResource.generateCylinder(height: spec.size.y, radius: spec.size.x)
        case .cone:
            return MeshResource.generateCone(height: spec.size.y, radius: spec.size.x)
        case .plane:
            return MeshResource.generatePlane(width: spec.size.x, height: spec.size.y)
        }
    }

    private func makeMaterial(_ spec: MaterialSpec) -> Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(
            red: CGFloat(spec.baseColor.r),
            green: CGFloat(spec.baseColor.g),
            blue: CGFloat(spec.baseColor.b),
            alpha: CGFloat(spec.baseColor.a)
        ))
        material.metallic = .init(floatLiteral: spec.metallic)
        material.roughness = .init(floatLiteral: spec.roughness)
        material.emissiveColor = .init(color: UIColor(
            red: CGFloat(spec.emissiveColor.r),
            green: CGFloat(spec.emissiveColor.g),
            blue: CGFloat(spec.emissiveColor.b),
            alpha: CGFloat(spec.emissiveColor.a)
        ))
        material.emissiveIntensity = spec.emissiveIntensity
        // `MaterialBlending` mapping is a Phase 3 concern — PhysicallyBasedMaterial
        // doesn't carry a 1:1 "additive vs alpha" toggle the way ParticleEmitter does.
        return material
    }

    private func makeTextEntity(_ def: EntityDefinition) -> Entity {
        guard let text = def.text else { return Entity() }
        let mesh = MeshResource.generateText(
            text.text,
            extrusionDepth: 0.005,
            font: .systemFont(ofSize: CGFloat(text.fontSize)),
            containerFrame: text.maxWidth.map { CGRect(x: 0, y: 0, width: CGFloat($0), height: 0) } ?? .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let color = UIColor(
            red: CGFloat(text.color.r),
            green: CGFloat(text.color.g),
            blue: CGFloat(text.color.b),
            alpha: CGFloat(text.color.a)
        )
        var material = UnlitMaterial()
        material.color = .init(tint: color)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func makeLightEntity(_ def: EntityDefinition) -> Entity {
        guard let spec = def.light else { return Entity() }
        let entity = Entity()
        switch spec.kind {
        case .directional:
            var light = DirectionalLightComponent()
            light.color = uiColor(spec.color)
            light.intensity = spec.intensity
            entity.components.set(light)
        case .point:
            var light = PointLightComponent()
            light.color = uiColor(spec.color)
            light.intensity = spec.intensity
            light.attenuationRadius = spec.range ?? 5
            entity.components.set(light)
        case .spot:
            var light = SpotLightComponent()
            light.color = uiColor(spec.color)
            light.intensity = spec.intensity
            light.attenuationRadius = spec.range ?? 5
            light.outerAngleInDegrees = spec.spotAngle ?? 45
            entity.components.set(light)
        case .ambient:
            // RealityKit doesn't have an ambient light component; approximate
            // with a low-intensity directional setup or leave to environment IBL.
            var light = DirectionalLightComponent()
            light.color = uiColor(spec.color)
            light.intensity = spec.intensity * 0.25
            entity.components.set(light)
        }
        return entity
    }

    private func makeVideoPanel(_ def: EntityDefinition) -> Entity {
        // Phase 5.5 fix: build an *empty* entity, not a ModelEntity with a
        // tinted UnlitMaterial. The previous placeholder rendered a flat
        // colored rectangle on the same plane as the eventual video and
        // looked awful — and on visionOS, AVPlayer's VideoPlayerComponent
        // didn't reliably replace that placeholder material when the
        // chapter's `playVideo` action ran, so the gray rectangle stuck
        // around for the entire video step.
        //
        // Now `VideoPlaybackManager.attachToPresentation` is responsible
        // for setting the ModelComponent (plane mesh + VideoMaterial) on
        // the entity when playVideo fires. Until then the entity is just
        // an invisible transform anchor — exactly what authoring expects.
        //
        // `spec` is intentionally unused for now; future revisions could
        // honor `placeholderColor` by drawing a thin rim or label, but
        // never on the video plane itself.
        _ = def.videoPanel
        return Entity()
    }

    private func uiColor(_ c: ColorRGBA) -> UIColor {
        UIColor(
            red: CGFloat(c.r),
            green: CGFloat(c.g),
            blue: CGFloat(c.b),
            alpha: CGFloat(c.a)
        )
    }

    private func applyTransform(_ transform: TransformData, to entity: Entity) {
        entity.position = SIMD3(transform.position)
        entity.scale = SIMD3(transform.scale)
        entity.orientation = simd_quatf(
            ix: transform.rotation.x,
            iy: transform.rotation.y,
            iz: transform.rotation.z,
            r: transform.rotation.w
        )
    }
}
