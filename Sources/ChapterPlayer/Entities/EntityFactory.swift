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
//
//  `.particles` entities resolve their `particlePresetId` against the
//  document's `particlePresets` and render a real `ParticleEmitterComponent`
//  (see ParticleEmitterEntity.swift for the format → RealityKit mapping).
//

import Foundation
import RealityKit
import UIKit
import simd
import ChapterScript

@MainActor
public final class EntityFactory {

    public init() {
        ParticleBurstOnRevealComponent.registerComponent()
    }

    /// Resolver used to locate on-disk URLs for image entities (so an
    /// "Add Image" reveal renders as an in-scene textured plane). Set by
    /// `DocumentEntityLoader.materialize` from the loaded experience.
    public var mediaResolver: MediaResolver?

    /// `ParticleEmitterPreset.id` → preset, for `.particles` entities. Set
    /// by `DocumentEntityLoader.materialize` from the loaded document's
    /// `particlePresets` on every (re)materialization, so live-sync preset
    /// upserts re-render on the next document swap.
    public var particlePresets: [String: ParticleEmitterPreset] = [:]

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
            entity = makeUSDZ(definition)
        case .text3D:
            entity = makeTextEntity(definition)
        case .light:
            entity = makeLightEntity(definition)
        case .videoPanel:
            entity = makeVideoPanel(definition)
        case .particles:
            entity = makeParticleEmitter(definition)
        case .audioEmitter:
            // A bare Entity, like a light — no geometry, nothing to see.
            // Building it is what registers the name, and registration is the
            // whole point: `applySequenceAnimationTracks` writes its pose from
            // the sequence's `EntityAnimationTrack`, and `playSpatial` parents
            // the sound to it. RealityKit then carries the sound along.
            entity = Entity()
        case .placeholder:
            // BLOCKING CONTENT BUILDS NOTHING AT RUNTIME.
            //
            // A placeholder stands in for media that does not exist yet. The
            // authoring tools draw a neutral proxy so the shot can be framed;
            // the player must not, because a grey box on device is
            // indistinguishable from a bug and could reach an audience. An
            // entity that isn't built simply never appears, and every action
            // naming it is a no-op — which is the truth about an unfinished
            // shot.
            return nil
        case .custom:
            if let id = definition.customFactoryId, let make = customFactories[id] {
                entity = make(definition)
            } else if Self.isImageFile(definition.id) {
                // Maestro "Add Image" entities travel as custom; render
                // them as in-scene textured planes.
                entity = makeImagePlane(definition)
            } else {
                return nil
            }
        }

        entity.name = definition.id
        applyTransform(definition.transform, to: entity)
        entity.isEnabled = definition.initiallyEnabled
        return entity
    }

    // MARK: - Built-in builders

    /// True when an entity id names an image file the player can texture
    /// onto an in-scene plane.
    static func isImageFile(_ id: String) -> Bool {
        let ext = (id as NSString).pathExtension.lowercased()
        return ["heic", "jpg", "jpeg", "png"].contains(ext)
    }

    /// Load a USDZ asset (e.g. a Maestro-imported model) and parent it
    /// under a placeholder Entity so the caller can apply the
    /// EntityDefinition's transform without waiting for the async load.
    /// The model swaps in once `Entity(contentsOf:)` resolves.
    private func makeUSDZ(_ def: EntityDefinition) -> Entity {
        let container = Entity()
        // The id is also the filename; the usdzAssetId field doubles as
        // the same when Maestro emits the definition.
        let assetId = def.usdzAssetId ?? def.id
        guard let url = mediaResolver?.url(for: assetId, kind: .usdz) else {
            // Fall back to the main bundle so apps that ship USDZs as
            // resources still resolve.
            if let bundled = Bundle.main.url(forResource: (assetId as NSString).deletingPathExtension, withExtension: "usdz") {
                loadUSDZ(from: bundled, into: container, animation: def.usdzAnimation)
            }
            return container
        }
        loadUSDZ(from: url, into: container, animation: def.usdzAnimation)
        return container
    }

    private func loadUSDZ(from url: URL, into container: Entity, animation: UsdzAnimationSpec? = nil) {
        Task { @MainActor in
            guard let loaded = try? await Entity(contentsOf: url) else { return }
            container.addChild(loaded)
            if let animation, animation.enabled {
                Self.playEmbeddedAnimations(on: loaded, spec: animation)
            }
        }
    }

    /// Play every embedded animation clip in a loaded USDZ's subtree
    /// (clips live on whichever node defines them, not the root).
    /// Public: editors reuse this for live toggling.
    public static func playEmbeddedAnimations(on entity: Entity, spec: UsdzAnimationSpec) {
        var stack: [Entity] = [entity]
        while let e = stack.popLast() {
            for animation in e.availableAnimations {
                let resource = spec.loop ? animation.repeat() : animation
                let controller = e.playAnimation(resource, transitionDuration: 0, startsPaused: false)
                controller.speed = spec.speed
            }
            stack.append(contentsOf: e.children)
        }
    }

    /// Reverse of `playEmbeddedAnimations` — stop every clip in the
    /// subtree (the model holds its current pose).
    public static func stopEmbeddedAnimations(on entity: Entity) {
        var stack: [Entity] = [entity]
        while let e = stack.popLast() {
            e.stopAllAnimations()
            stack.append(contentsOf: e.children)
        }
    }

    /// Build a flat plane textured with an image asset (an "Add Image"
    /// reveal). Returns a neutral placeholder immediately and swaps in the
    /// texture (and the image's aspect ratio) once it loads asynchronously.
    private func makeImagePlane(_ def: EntityDefinition) -> Entity {
        let model = ModelEntity(
            mesh: .generatePlane(width: 1.0, height: 1.0),
            materials: [UnlitMaterial(color: .gray)]
        )
        guard let url = mediaResolver?.url(for: def.id, kind: .image) else { return model }
        Task { @MainActor in
            guard let texture = try? await TextureResource(contentsOf: url) else { return }
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(texture))
            model.model?.materials = [mat]
            let w = Float(texture.width), h = Float(texture.height)
            if w > 0, h > 0 {
                model.model?.mesh = .generatePlane(width: w / h, height: 1.0)
            }
        }
        return model
    }

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
            light.attenuationRadius = spec.range ?? LightSpec.defaultRange
            entity.components.set(light)
        case .spot:
            var light = SpotLightComponent()
            light.color = uiColor(spec.color)
            light.intensity = spec.intensity
            light.attenuationRadius = spec.range ?? LightSpec.defaultRange
            light.outerAngleInDegrees = spec.spotAngle ?? LightSpec.defaultSpotAngleDegrees
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
        // sequence's `playVideo` action ran, so the gray rectangle stuck
        // around for the entire video step.
        //
        // Now `VideoPlaybackManager.attachToPresentation` is responsible
        // for setting the ModelComponent (plane mesh + VideoMaterial) on
        // the entity when playVideo fires. Until then the entity is just
        // an invisible transform anchor — exactly what authoring expects.
        let entity = Entity()
        // Panel styling rides on the entity so the manager (which only
        // knows the presentation's width/height) can honor it when it
        // generates the plane at bind time.
        // The panel's authored APPEARANCE rides on the entity, because the
        // manager binds from the presentation (width/height) and cannot see the
        // definition. Stamped whenever any of it is non-default.
        let presentation = def.videoPanel?.spatialPresentation ?? .flat
        let tinting = def.videoPanel?.passthroughTinting ?? false
        let radius = def.videoPanel?.cornerRadius ?? 0
        if radius > 0 || presentation != .flat || tinting {
            entity.components.set(VideoPanelStyleComponent(
                cornerRadius: radius,
                spatialPresentation: presentation,
                passthroughTinting: tinting))
        }
        return entity
    }

    // MARK: - Panel styling

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

/// Styling for a video panel entity that the plane-generating code can't
/// derive from the presentation alone. Stamped by `EntityFactory` from
/// `VideoPanelSpec` at materialize; read by
/// `VideoPlaybackManager.attachToPresentation` when it builds the plane.
public struct VideoPanelStyleComponent: Component {
    /// Rounded corner radius in meters (the plane's geometry is clipped;
    /// the video texture stays rect-mapped).
    public var cornerRadius: Float
    /// AUTHORED SPATIAL PRESENTATION for this panel. `.flat` is what every
    /// Chapter written before the field does, and is the path this player has
    /// always taken; `.spatial` asks for the system's own stereo presentation.
    public var spatialPresentation: SpatialVideoPresentation
    /// Only consulted under `.spatial`.
    public var passthroughTinting: Bool

    public init(cornerRadius: Float,
                spatialPresentation: SpatialVideoPresentation = .flat,
                passthroughTinting: Bool = false) {
        self.cornerRadius = cornerRadius
        self.spatialPresentation = spatialPresentation
        self.passthroughTinting = passthroughTinting
    }
}
