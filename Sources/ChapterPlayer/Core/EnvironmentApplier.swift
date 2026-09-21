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
import AVFoundation
import CoreGraphics
import ImageIO
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

            /// Where the light's picture comes from.
            public var source: LightSource

            public init(intensityExponent: Float, color: SIMD3<Float>,
                        source: LightSource = .neutral) {
                self.intensityExponent = intensityExponent
                self.color = color
                self.source = source
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

    /// WHAT SURROUNDS THE VIEWER, as far as light is concerned.
    ///
    /// RealityKit lights an immersive space from the system's probe of the
    /// REAL ROOM, at any immersion. That is right in passthrough, where it is
    /// what grounds content among the furniture, and wrong the moment the
    /// viewer stands somewhere else: a model on a noon beach lit by a dim
    /// living room, and lit differently in every room it is ever watched in.
    public enum Surround: Equatable, Sendable {
        /// Passthrough, a window, or a fully immersive Sequence with nothing
        /// around the viewer. The room's light is the true light.
        case room
        /// An equirectangular image Environment.
        case image(file: String)
        /// An immersive video, as an Environment cue or as a Clip. `time` is
        /// the media time the light is taken at; `coverage` the fraction of
        /// the full turn its field fills (0.5 for a 180).
        case video(file: String, time: Double, layout: VideoLayout, coverage: Float)
        /// A model Environment. Its sky cannot be read back out of RealityKit.
        case model
    }

    /// The picture an image-based light is built from.
    public enum LightSource: Equatable, Sendable {
        /// Brightest overhead, falling to a dim floor: no place in particular.
        case neutral
        /// The Environment's own image: the light is the world's.
        case image(file: String)
        /// One frame of the surrounding video, placed by its coverage.
        case videoFrame(file: String, time: Double, layout: VideoLayout, coverage: Float)
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

    /// THE RULE. Anything that surrounds the viewer REPLACES the room's light,
    /// at every preset including "natural" (zero stops): the point is whose
    /// light it is, not how bright. The preset still moves it by its stops.
    /// With nothing around the viewer this is `plan(for:)`, unchanged.
    public nonisolated static func plan(for spec: EnvironmentSpec?, surround: Surround) -> Plan {
        let source: LightSource
        switch surround {
        case .room: return plan(for: spec)
        case .image(let file): source = .image(file: file)
        case .video(let file, let time, let layout, let coverage):
            source = .videoFrame(file: file, time: time, layout: layout, coverage: coverage)
        case .model: source = .neutral
        }
        let stops = spec.map { stopsFromNatural(lighting: $0.lighting) } ?? 0
        return Plan(imageLight: .init(
            intensityExponent: headsetBaselineExponent + stops,
            color: SIMD3<Float>(1, 1, 1), source: source))
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
    /// Probes built from media, by source. Small (a probe is downsampled) and
    /// bounded: a Chapter has a handful of Environments.
    private static var mediaProbeCache: [String: EnvironmentResource] = [:]
    /// Resolves an Environment's file to bytes on this device. The host's.
    public var mediaURL: ((_ file: String, _ isVideo: Bool) -> URL?)?

    public init() {}

    /// Make `sceneRoot` match `spec`. Safe to call any number of times.
    public func apply(_ spec: EnvironmentSpec?, surround: Surround = .room, to sceneRoot: Entity) {
        generation &+= 1
        if let previous = lastRoot, previous !== sceneRoot {
            Self.removeOwned(from: previous)
        }
        lastRoot = sceneRoot

        let plan = Self.plan(for: spec, surround: surround)
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

        if light.source != .neutral {
            applyMediaLight(light, on: owned, root: sceneRoot)
            return
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

    // MARK: - Light from the world itself

    /// Build (or reuse) a probe from the Environment's own picture.
    ///
    /// THE NEUTRAL PROBE GOES IN FIRST, synchronously when it is cached: the
    /// room's light is wrong from the first frame, and a media probe takes a
    /// decode to build. If the media cannot be read the neutral one stands,
    /// which is still not somebody's living room.
    private func applyMediaLight(_ light: Plan.ImageLight, on owned: Entity, root: Entity) {
        let key = Self.cacheKey(light.source)
        if let cached = Self.mediaProbeCache[key] {
            Self.install(light, probe: cached, on: owned, root: root)
            return
        }
        if let neutral = Self.probeCache[light.color] {
            Self.install(light, probe: neutral, on: owned, root: root)
        }
        let expected = generation
        let resolve = mediaURL
        Task { @MainActor [weak self, weak root, weak owned] in
            do {
                let image: CGImage?
                switch light.source {
                case .neutral:
                    image = nil
                case .image(let file):
                    image = resolve?(file, false).flatMap { Self.downsampledImage(at: $0) }
                case .videoFrame(let file, let time, let layout, let coverage):
                    if let url = resolve?(file, true),
                       let frame = await Self.videoFrame(of: url, at: time) {
                        image = Self.probeCanvas(frame: frame, layout: layout, coverage: coverage)
                    } else {
                        image = nil
                    }
                }
                var probe: EnvironmentResource?
                if let image {
                    probe = try await EnvironmentResource(equirectangular: image,
                                                          withName: "ChapterWorldProbe")
                    Self.mediaProbeCache[key] = probe
                } else {
                    environmentLogger.warning("no picture to light from for \(key, privacy: .public); the neutral light stands")
                    if Self.probeCache[light.color] == nil, let neutralImage = Self.probeImage(color: light.color) {
                        let neutral = try await EnvironmentResource(equirectangular: neutralImage,
                                                                    withName: "ChapterEnvironmentProbe")
                        Self.probeCache[light.color] = neutral
                        probe = neutral
                    }
                }
                guard let self, self.generation == expected, let probe,
                      let root, let owned, owned.parent === root else { return }
                Self.install(light, probe: probe, on: owned, root: root)
            } catch {
                environmentLogger.error("world light probe failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func cacheKey(_ source: LightSource) -> String {
        switch source {
        case .neutral: return "neutral"
        case .image(let file): return "image|\(file)"
        case .videoFrame(let file, let time, let layout, let coverage):
            return "video|\(file)|\(Int(time.rounded()))|\(layout.rawValue)|\(coverage)"
        }
    }

    /// A probe needs the world's broad light, not its detail, and a full
    /// equirectangular plate is tens of megapixels.
    private nonisolated static func downsampledImage(at url: URL, maxPixel: Int = 1024) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func videoFrame(of url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }

    /// ONE EYE, WHERE ITS FIELD PUTS IT. A frame-packed stereo frame holds
    /// two pictures and the light wants one. A field narrower than the full
    /// turn is drawn centered on the forward direction over black: behind a
    /// 180 there is no picture, and no light comes from there either.
    nonisolated static func probeCanvas(frame: CGImage, layout: VideoLayout, coverage: Float) -> CGImage? {
        var eye = frame
        switch layout {
        case .sideBySide:
            eye = frame.cropping(to: CGRect(x: 0, y: 0, width: frame.width / 2, height: frame.height)) ?? frame
        case .overUnder:
            eye = frame.cropping(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height / 2)) ?? frame
        case .mono, .multiviewHEVC:
            break
        }
        let width = 1024, height = 512
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let span = CGFloat(min(max(coverage, 0.05), 1)) * CGFloat(width)
        context.interpolationQuality = .medium
        context.draw(eye, in: CGRect(x: (CGFloat(width) - span) / 2, y: 0, width: span, height: CGFloat(height)))
        return context.makeImage()
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
