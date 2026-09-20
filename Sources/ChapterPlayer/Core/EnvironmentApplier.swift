//
//  EnvironmentApplier.swift
//  ChapterPlayer
//
//  THE CHAPTER'S ENVIRONMENT, ON THE HEADSET.
//
//  `ChapterDocument.environment` (`EnvironmentSpec`: a lighting preset tag, a
//  fog toggle and a fog density) was authored on the Mac, shown in the Mac
//  Viewer, and read by nothing on the device. A Chapter's lighting was
//  Mac-only. This is the missing consumer.
//
//  WHAT THE MAC DOES, BECAUSE THE HEADSET HAS TO MATCH IT.
//
//  The Mac Viewer (`SceneViewport.updateEnvironment`) maps the lighting tag
//  onto exactly one thing that lights content: the image-based light's
//  `intensityExponent` ("natural" and unknown tags 2.0, "studio" 3.0,
//  "sunset" 1.5, "night" 0.5, "overcast" 1.8). It adds no key light and no
//  color cast; the tinted surround it also picks is a Viewer background, not
//  light. So the honest headset mapping is the same single control: an
//  image-based light whose exponent moves by the same number of STOPS.
//
//  RELATIVE, NOT ABSOLUTE. The Mac's 2.0 is a baseline tuned for ARView's
//  built-in light probe. Copying "3.0" onto a headset would be eight times
//  over. What the author judged is the DIFFERENCE between presets, so each
//  preset is carried as its offset from "natural".
//
//  "NATURAL" LEAVES THE ROOM ALONE. In a mixed immersive space the system
//  lights content from the real room, which is what grounds it there. The
//  Mac's default preset is "natural", so almost every Chapter carries it; an
//  empty plan for it means those Chapters render exactly as they did before
//  this file existed. Only a preset that ASKS for a different light replaces
//  the room's probe with a neutral synthetic one at the preset's offset.
//
//  WHAT IS REFUSED RATHER THAN FAKED. RealityKit on visionOS has no scene
//  fog. A translucent shell or a per-material fade would be a different
//  effect under the same name, so fog is reported by `unsupportedFields`
//  and the editor says so in words.
//
//  IDEMPOTENT BY OWNERSHIP. Everything this type adds lives on ONE named
//  child of the scene root (`ownedEntityName`) plus one receiver component on
//  the root itself. Applying twice updates that child; applying `nil` (or a
//  plan with nothing in it) removes both.
//

import Foundation
import CoreGraphics
import RealityKit
import ChapterScript
import os.log

private let environmentLogger = Logger(subsystem: "ChapterPlayer", category: "Environment")

@MainActor
public final class EnvironmentApplier {

    // MARK: - Pure plan

    /// What the runtime will do for a spec, as a value. Built by `plan(for:)`
    /// with no RealityKit involved so it can be tested anywhere.
    public struct Plan: Equatable, Sendable {
        /// A synthetic image-based light that replaces the room's probe for
        /// everything under the scene root.
        public struct ImageLight: Equatable, Sendable {
            /// Stops relative to the headset baseline; RealityKit's
            /// `ImageBasedLightComponent.intensityExponent`.
            public var intensityExponent: Float
            /// Linear RGB of the light. Neutral for every Mac preset, because
            /// the Mac Viewer does not tint its light either.
            public var color: SIMD3<Float>

            public init(intensityExponent: Float, color: SIMD3<Float>) {
                self.intensityExponent = intensityExponent
                self.color = color
            }
        }

        /// `nil` means "leave the system's lighting alone".
        public var imageLight: ImageLight?

        public init(imageLight: ImageLight? = nil) {
            self.imageLight = imageLight
        }

        /// Nothing to add to the scene.
        public var isEmpty: Bool { imageLight == nil }
    }

    /// The Mac Viewer's `intensityExponent` per lighting tag. Kept as the
    /// Mac's own numbers so the two tables can be compared by eye.
    nonisolated static let macIntensityExponents: [String: Float] = [
        "natural": 2.0,
        "studio": 3.0,
        "sunset": 1.5,
        "night": 0.5,
        "overcast": 1.8,
    ]

    /// The Mac's exponent for "natural" and for any tag it does not know.
    nonisolated static let macBaselineExponent: Float = 2.0

    /// Exponent a synthetic light gets for a zero-stop offset. A tuning
    /// constant for the device: see the header.
    nonisolated static let headsetBaselineExponent: Float = 0.0

    /// Stops away from "natural" for a lighting tag. Unknown tags are 0, the
    /// same fallback the Mac Viewer's `default:` takes.
    public nonisolated static func stopsFromNatural(lighting: String) -> Float {
        (macIntensityExponents[lighting] ?? macBaselineExponent) - macBaselineExponent
    }

    public nonisolated static func plan(for spec: EnvironmentSpec?) -> Plan {
        guard let spec else { return Plan() }
        let stops = stopsFromNatural(lighting: spec.lighting)
        // Zero stops is the room's own light. Replacing the probe to change
        // nothing would only cost the content its grounding.
        guard stops != 0 else { return Plan() }
        return Plan(imageLight: .init(
            intensityExponent: headsetBaselineExponent + stops,
            color: SIMD3<Float>(1, 1, 1)
        ))
    }

    /// Author-readable names of the fields set in `spec` that Vision Pro
    /// cannot draw. Empty when everything set is honored.
    public nonisolated static func unsupportedFields(in spec: EnvironmentSpec) -> [String] {
        var fields: [String] = []
        // Density only means anything while fog is on, so it is not listed
        // separately: "Fog" covers it.
        if spec.fogEnabled { fields.append("Fog") }
        return fields
    }

    /// One sentence for the editor, or `nil` when nothing is refused.
    public nonisolated static func unsupportedNotice(for spec: EnvironmentSpec) -> String? {
        let fields = unsupportedFields(in: spec)
        guard let first = fields.first else { return nil }
        if fields.count == 1 { return "\(first) is not drawn on Vision Pro." }
        let head = fields.dropLast().joined(separator: ", ")
        return "\(head) and \(fields[fields.count - 1]) are not drawn on Vision Pro."
    }

    // MARK: - RealityKit application

    /// Name of the single child this type owns under the scene root.
    public nonisolated static let ownedEntityName = "ChapterEnvironment"

    /// The root the owned child was last added to. A remounted immersive
    /// space hands over a NEW root; the old one must not keep our light.
    private weak var lastRoot: Entity?
    /// Bumped per apply so a light probe that finishes building after a newer
    /// apply does not install itself over it.
    private var generation: UInt64 = 0

    /// Neutral probes are identical for every preset (only the exponent
    /// differs), so one is built per distinct color and kept.
    private static var probeCache: [SIMD3<Float>: EnvironmentResource] = [:]

    public init() {}

    /// Make `sceneRoot` match `spec`. Safe to call any number of times.
    public func apply(_ spec: EnvironmentSpec?, to sceneRoot: Entity) {
        generation &+= 1
        if let previous = lastRoot, previous !== sceneRoot {
            Self.removeOwned(from: previous)
        }
        lastRoot = sceneRoot

        let plan = Self.plan(for: spec)
        guard let light = plan.imageLight else {
            Self.removeOwned(from: sceneRoot)
            return
        }

        let owned: Entity
        if let existing = Self.ownedEntity(in: sceneRoot) {
            owned = existing
        } else {
            owned = Entity()
            owned.name = Self.ownedEntityName
            sceneRoot.addChild(owned)
        }

        if let probe = Self.probeCache[light.color] {
            Self.install(light, probe: probe, on: owned, root: sceneRoot)
            return
        }

        // Until the probe exists the root keeps the system's light: a
        // receiver pointing at an entity with no light would render the
        // content black for the duration of the build.
        let expected = generation
        Task { @MainActor [weak self, weak sceneRoot, weak owned] in
            do {
                let probe: EnvironmentResource
                if let cached = Self.probeCache[light.color] {
                    probe = cached
                } else {
                    guard let image = Self.probeImage(color: light.color) else {
                        environmentLogger.error("could not draw the light probe image")
                        return
                    }
                    probe = try await EnvironmentResource(
                        equirectangular: image,
                        withName: "ChapterEnvironmentProbe"
                    )
                    Self.probeCache[light.color] = probe
                }
                guard let self, self.generation == expected,
                      let sceneRoot, let owned, owned.parent === sceneRoot else { return }
                Self.install(light, probe: probe, on: owned, root: sceneRoot)
            } catch {
                environmentLogger.error("light probe build failed: \(error.localizedDescription)")
            }
        }
    }

    private static func ownedEntity(in root: Entity) -> Entity? {
        root.children.first { $0.name == ownedEntityName }
    }

    private static func removeOwned(from root: Entity) {
        // Every match, not the first: a root that somehow collected two must
        // come back to none.
        for child in root.children where child.name == ownedEntityName {
            child.removeFromParent()
        }
        root.components.remove(ImageBasedLightReceiverComponent.self)
    }

    private static func install(
        _ light: Plan.ImageLight,
        probe: EnvironmentResource,
        on owned: Entity,
        root: Entity
    ) {
        owned.components.set(ImageBasedLightComponent(
            source: .single(probe),
            intensityExponent: light.intensityExponent
        ))
        // A receiver on the root covers every descendant, so entities that
        // `materialize` rebuilds later are lit without another apply.
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: owned))
    }

    /// A small equirectangular probe: brightest overhead, falling to a dim
    /// floor, so lit content keeps a sense of "up" instead of going flat.
    private nonisolated static func probeImage(color: SIMD3<Float>) -> CGImage? {
        let width = 128
        let height = 64
        guard let space = CGColorSpace(name: CGColorSpace.linearSRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        for row in 0..<height {
            // Row 0 of a CGContext is the BOTTOM of the image: the floor.
            let elevation = Float(row) / Float(height - 1)
            let level = 0.35 + 0.65 * elevation
            context.setFillColor(
                red: CGFloat(min(max(color.x * level, 0), 1)),
                green: CGFloat(min(max(color.y * level, 0), 1)),
                blue: CGFloat(min(max(color.z * level, 0), 1)),
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        return context.makeImage()
    }
}
