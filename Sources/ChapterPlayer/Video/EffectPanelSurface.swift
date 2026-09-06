//
//  EffectPanelSurface.swift
//  ChapterPlayer
//
//  THE PLAYER'S PER-FRAME VIDEO SURFACE — the mirror of Maestro Studio's
//  `EffectPanelCompositor` (FL-09 … FL-13). A flat panel whose occurrence
//  carries an enabled Effect stack, or sits inside a dissolve window, stops
//  riding `VideoMaterial` and rides a `LowLevelTexture` fed per displayed
//  frame: AVPlayerItemVideoOutput → CIImage → THE one (mirrored)
//  `EffectEvaluator` → a GPU-resident CIContext with the SAME unmanaged
//  working-space contract the editors and export use — which is what makes
//  device playback the picture the author graded.
//
//  Zero work when nothing needs it: the surface is bound only while a
//  panel carries a stack or a window, and restored — not short-circuited —
//  when neither remains. Latest-wins: a tick that arrives while a command
//  buffer is in flight is skipped, never queued.
//
//  A dissolve's OUTGOING side is its predecessor's LAST FRAME, held — the
//  Kit's window rule maps the butted predecessor's time past its end to a
//  held source time — decoded once for the window and mixed by progress
//  through the same `CIMix` the Mac uses.
//

import Foundation
import AVFoundation
import CoreImage
import Metal
import RealityKit
import ChapterScript

@MainActor
final class EffectPanelSurface {

    struct Job {
        let channel: String
        /// ANY Entity carrying a `ModelComponent` — a flat panel, or the
        /// immersive shell when a backdrop's stack put a mesh on it. The
        /// surface only ever needs a material slot to write into.
        let entity: Entity
        let player: AVPlayer
        let effects: [EffectInstance]
        let keyTracks: [EffectKeyTrack]
        let lutData: [String: Data]
        let timelineTime: Double
        let sourceTime: Double
        /// FL-12: the held outgoing frame and the window's progress, while
        /// a dissolve is live on this panel.
        var outgoing: CIImage? = nil
        var outgoingEffects: [EffectInstance] = []
        var progress: Double? = nil
    }

    /// FL-11: an occurrence some Mask in this tick takes its coverage from.
    ///
    /// The surface is the only thing holding a decoder tap per channel, so
    /// the host names the occurrence and where it is playing and the frame
    /// is pulled HERE — the same shape the Mac Viewer uses, where the
    /// caller gathers `matteFrames` because it is the only thing that knows
    /// what is playing where.
    struct MatteSource {
        let occurrenceId: String
        let channel: String
        let player: AVPlayer
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    /// THE SAME CONTRACT AS THE EDITORS AND EXPORT (A-6): unmanaged working
    /// space — the stack operates on the source's display-referred bits.
    private let ciContext: CIContext?

    private struct Surface {
        let texture: LowLevelTexture
        let resource: TextureResource
        var width: Int
        var height: Int
        var entityIdentity: ObjectIdentifier
        var originals: [any RealityKit.Material]
    }

    private var surfaces: [String: Surface] = [:]
    private var outputs: [String: AVPlayerItemVideoOutput] = [:]
    private var lastFrames: [String: CIImage] = [:]
    private var inFlight = false
    /// TEST SEAM / the zero-work assertion: composited frames.
    private(set) var compositions = 0

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.ciContext = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false,
                                               .workingColorSpace: NSNull()])
        }
    }

    var hasSurfaces: Bool { !surfaces.isEmpty }

    // MARK: - Frames

    /// The current frame's pixels for a channel's player, or nil when
    /// nothing new is decodable. Attaches the tap to the LIVE item on demand
    /// and re-attaches across looper wraps — the Mac's `pullFrame`.
    func pullFrame(channel: String, player: AVPlayer, isPlaying: Bool) -> CVPixelBuffer? {
        guard let item = player.currentItem else { return nil }
        let output: AVPlayerItemVideoOutput
        if let existing = outputs[channel] {
            output = existing
        } else {
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            outputs[channel] = output
        }
        if !item.outputs.contains(where: { $0 === output }) {
            if let queue = player as? AVQueuePlayer {
                for stale in queue.items() where stale !== item {
                    if stale.outputs.contains(where: { $0 === output }) { stale.remove(output) }
                }
            }
            item.add(output)
        }
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) || !isPlaying else { return nil }
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    // MARK: - The tick

    /// One tick: pull, evaluate, mix, render. Returns how many panels were
    /// composited this tick.
    @discardableResult
    func tick(jobs: [Job], matteSources: [MatteSource] = []) -> Int {
        guard let ciContext, let commandQueue else { return 0 }
        guard !inFlight else { return 0 }

        // MATTES FIRST, so a mask reads THIS tick's frame of the clip it
        // points at rather than the previous one — and so a matte source
        // that composites nothing of its own still gets its tap pulled.
        var mattes: [String: CIImage] = [:]
        for source in matteSources {
            if let buffer = pullFrame(channel: source.channel, player: source.player,
                                      isPlaying: source.player.rate > 0.001) {
                let image = CIImage(cvPixelBuffer: buffer)
                lastFrames[source.channel] = image
                mattes[source.occurrenceId] = image
            } else if let held = lastFrames[source.channel] {
                mattes[source.occurrenceId] = held
            }
        }
        // Nil, not an empty closure: "no matte was offered" and "the matte
        // is not resolvable" are one answer to the stage — it bypasses and
        // leaves the picture alone — but only a nil resolver keeps the
        // environment identical to a document that names no matte at all.
        // Hoisted rather than written inline: a `@Sendable` closure typed
        // through a ternary infers against `Dictionary.Index` and fails to
        // convert. The same shape the Mac compositor uses.
        var matteResolver: (@Sendable (String) -> CIImage?)?
        if !mattes.isEmpty {
            let resolved = mattes
            matteResolver = { name in resolved[name] }
        }

        var commandBuffer: MTLCommandBuffer?
        var rendered = 0
        for job in jobs {
            let isPlaying = job.player.rate > 0.001
            var input: CIImage
            if let buffer = pullFrame(channel: job.channel, player: job.player, isPlaying: isPlaying) {
                input = CIImage(cvPixelBuffer: buffer)
                lastFrames[job.channel] = input
            } else if let held = lastFrames[job.channel] {
                // Parked (a freeze, a reverse span, a pause): the last frame
                // stays composited so a keyed parameter or a dissolve keeps
                // moving over it.
                input = held
            } else {
                continue
            }
            let extent = input.extent
            let environment = EffectRenderEnvironment(
                tier: .full, timelineTime: job.timelineTime, sourceTime: job.sourceTime,
                sourceData: { [lut = job.lutData] file in lut[file] },
                showMatte: false,
                matteImage: matteResolver)
            var result = EffectEvaluator.evaluate(
                stack: job.effects, input: input,
                keyTracks: job.keyTracks, environment: environment)
            // FL-12: THE MIX — both sides through their own full stacks,
            // then a linear, premultiplied blend by the window's progress.
            if let progress = job.progress, var outgoing = job.outgoing {
                if !job.outgoingEffects.isEmpty {
                    outgoing = EffectEvaluator.evaluate(
                        stack: job.outgoingEffects, input: outgoing,
                        keyTracks: job.keyTracks, environment: environment).image
                }
                // The held frame is scaled onto the incoming extent so a
                // predecessor of another size still mixes edge to edge.
                let scaled = Self.fitted(outgoing, to: extent)
                let mixed = result.image.applyingFilter("CIMix", parameters: [
                    "inputBackgroundImage": scaled.cropped(to: extent),
                    "inputAmount": progress,
                ])
                result = EffectEvaluator.Result(
                    image: mixed, renderedCount: result.renderedCount + 1,
                    unrecognised: result.unrecognised)
            }

            let width = Int(extent.width)
            let height = Int(extent.height)
            guard width > 0, height > 0,
                  let surface = ensureSurface(for: job.channel, entity: job.entity,
                                              width: width, height: height)
            else { continue }
            if commandBuffer == nil { commandBuffer = commandQueue.makeCommandBuffer() }
            guard let commandBuffer else { continue }
            let target = surface.texture.replace(using: commandBuffer)
            // Row order: Core Image is bottom-up, the sampled texture
            // top-down — the same one flip the Mac compositor makes.
            let upright = result.image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -CGFloat(height)))
            ciContext.render(upright, to: target,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            compositions += 1
            rendered += 1
        }

        if let commandBuffer {
            inFlight = true
            commandBuffer.addCompletedHandler { [weak self] _ in
                Task { @MainActor [weak self] in self?.inFlight = false }
            }
            commandBuffer.commit()
        }
        return rendered
    }

    static func fitted(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0,
              abs(source.width - extent.width) > 0.5 || abs(source.height - extent.height) > 0.5
        else { return image }
        let transform = CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / source.width,
                                             y: extent.height / source.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return image.transformed(by: transform)
    }

    private func ensureSurface(for channel: String, entity: Entity,
                               width: Int, height: Int) -> Surface? {
        if var existing = surfaces[channel] {
            if existing.entityIdentity != ObjectIdentifier(entity) {
                existing.entityIdentity = ObjectIdentifier(entity)
                existing.originals = Self.materials(of: entity)
                bind(existing, to: entity)
                surfaces[channel] = existing
            }
            if existing.width == width, existing.height == height {
                return existing
            }
            restore(channel: channel, entity: entity)
        }
        var descriptor = LowLevelTexture.Descriptor()
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.textureUsage = [.shaderRead, .shaderWrite]
        guard let texture = try? LowLevelTexture(descriptor: descriptor),
              let resource = try? TextureResource(from: texture) else { return nil }
        let surface = Surface(texture: texture, resource: resource,
                              width: width, height: height,
                              entityIdentity: ObjectIdentifier(entity),
                              originals: Self.materials(of: entity))
        bind(surface, to: entity)
        surfaces[channel] = surface
        return surface
    }

    private func bind(_ surface: Surface, to entity: Entity) {
        var material = UnlitMaterial()
        material.color = .init(texture: .init(surface.resource))
        Self.setMaterials([material], on: entity)
    }

    /// The entity's model materials, through the COMPONENT rather than
    /// `ModelEntity.model` — the immersive shell is a plain `Entity` with a
    /// `ModelComponent` set on it, and the convenience accessor does not
    /// exist there.
    private static func materials(of entity: Entity) -> [any RealityKit.Material] {
        entity.components[ModelComponent.self]?.materials ?? []
    }

    private static func setMaterials(_ materials: [any RealityKit.Material], on entity: Entity) {
        guard var model = entity.components[ModelComponent.self] else { return }
        model.materials = materials
        entity.components.set(model)
    }

    /// A panel whose stack emptied and whose window closed goes back to its
    /// `VideoMaterial`.
    func restore(channel: String, entity: Entity?) {
        guard let surface = surfaces.removeValue(forKey: channel) else { return }
        lastFrames.removeValue(forKey: channel)
        if let entity, ObjectIdentifier(entity) == surface.entityIdentity {
            Self.setMaterials(surface.originals, on: entity)
        }
    }

    /// Drop the channel's tap and frame — the channel is gone.
    func forget(channel: String) {
        surfaces.removeValue(forKey: channel)
        outputs.removeValue(forKey: channel)
        lastFrames.removeValue(forKey: channel)
    }

    // MARK: - The held outgoing frame

    /// The predecessor's frame at `time`, decoded once — the held side of a
    /// dissolve. Exact-time, so the mix starts on the frame the cut left.
    nonisolated static func heldFrame(of url: URL, at seconds: Double) async -> CIImage? {
        let cgImage: CGImage? = await Task.detached {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            return try? await generator.image(at: time).image
        }.value
        guard let cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
