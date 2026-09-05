//
//  EffectEvaluator.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/EffectEvaluator.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import CoreImage
import ChapterScript

/// Everything an Effect's renderer may know about the instant.
public struct EffectRenderEnvironment: Sendable {
    public let tier: PlayerResolutionTier
    /// The Sequence clock (a `.timeline` parameter's clock).
    public let timelineTime: Double
    /// The MAPPED source time (a `.source` parameter's clock — FL-13's
    /// retime compensation arrives through this argument).
    public let sourceTime: Double
    /// Bytes of a `.sourceReference` parameter's file (a LUT, a matte),
    /// resolved by the host. Nil ⇒ the referencing stage bypasses and the
    /// Inspector reports; the reference itself is never dropped.
    public let sourceData: (@Sendable (String) -> Data?)?
    /// THE MATTE VIEW (FL-11): render coverage alone — how a key is
    /// actually judged. Authoring chrome; never set by export or runtime.
    public let showMatte: Bool

    public init(tier: PlayerResolutionTier, timelineTime: Double, sourceTime: Double,
                sourceData: (@Sendable (String) -> Data?)? = nil,
                showMatte: Bool = false) {
        self.tier = tier
        self.timelineTime = timelineTime
        self.sourceTime = sourceTime
        self.sourceData = sourceData
        self.showMatte = showMatte
    }
}

/// One Effect's pixel work: premultiplied in, premultiplied out — unless
/// the schema declared `operatesOnColorValues`, in which case the STAGE
/// has already unpremultiplied around the whole run.
public typealias EffectRenderer =
    @Sendable (CIImage, [String: EffectValue], EffectRenderEnvironment) -> CIImage

public enum EffectEvaluator {

    // MARK: - The built-in renderers

    /// The registry this build can render. FL-10/11/12/14 add entries; an
    /// id that resolves to nothing is KEPT in the stack and bypassed.
    public static let builtInRenderers: [String: EffectRenderer] = [
        ColorEffect.effectId: ColorEffect.renderer,
        MaskEffect.effectId: MaskEffect.renderer,
        KeyerEffects.chromaId: KeyerEffects.chromaRenderer,
        KeyerEffects.lumaId: KeyerEffects.lumaRenderer,
        EffectSchemaRegistry.referenceEffectId: { image, parameters, _ in
            // Mathematically transparent at its default (amount = 0); a
            // plain linear dim above it. Exists to PROVE the path, not to
            // ship a look.
            let amount = parameters["amount"]?.numberValue ?? 0
            guard amount > 0.0001 else { return image }
            let gain = CGFloat(1 - min(max(amount, 0), 1))
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        },
    ]

    // MARK: - Parameter resolution (stored → keyed → clamped)

    /// The value an Effect renders with at an instant: the stored value,
    /// overridden by its Key curve where one exists (the EXISTING
    /// animation evaluator — G6), then clamped by the schema for
    /// rendering. The stored value is never rewritten.
    public static func resolvedParameters(for instance: EffectInstance,
                                          schema: EffectSchema?,
                                          keyTracks: [EffectKeyTrack],
                                          environment: EffectRenderEnvironment) -> [String: EffectValue] {
        var resolved = instance.parameters
        guard let schema else { return resolved }

        let track = keyTracks.first { $0.instanceId == instance.id }
        for parameter in schema.parameters {
            var value = resolved[parameter.key] ?? parameter.defaultValue
            if parameter.kind.supportsInterpolation,
               let curve = track?.channels[parameter.key], curve.isAnimated {
                // Discrete kinds never reach here — type-enforced.
                let clock = parameter.timeReference == .source
                    ? environment.sourceTime : environment.timelineTime
                let rest = Float(value.numberValue ?? 0)
                let sampled = SequenceAnimationEvaluator.evaluate(
                    curve, at: clock, rest: rest)
                value = .number(Double(sampled))
            }
            resolved[parameter.key] = parameter.renderValue(from: value).value
        }
        return resolved
    }

    // MARK: - The bracket plan (FL-04, stage-owned)

    public struct Batch: Equatable {
        /// True: the STAGE unpremultiplies once before this run and
        /// repremultiplies once after it.
        public let bracketed: Bool
        public let instances: [EffectInstance]
    }

    /// The render plan: enabled, renderable Effects in authored order,
    /// grouped into contiguous runs by their color-values declaration.
    /// Bypassed and unrecognised Effects appear in NO batch — excluded
    /// from the graph, not rendered at zero strength.
    public static func batches(for stack: [EffectInstance],
                               renderers: [String: EffectRenderer]? = nil) -> [Batch] {
        let known = renderers ?? builtInRenderers
        var result: [Batch] = []
        for instance in stack {
            guard instance.enabled,
                  known[instance.effectId] != nil,
                  let schema = EffectSchemaRegistry.schema(for: instance.effectId)
                    ?? testSchemas[instance.effectId]
            else { continue }
            let bracketed = schema.operatesOnColorValues
            if var last = result.last, last.bracketed == bracketed {
                last = Batch(bracketed: bracketed,
                             instances: last.instances + [instance])
                result[result.count - 1] = last
            } else {
                result.append(Batch(bracketed: bracketed, instances: [instance]))
            }
        }
        return result
    }

    /// Schemas injected by tests (the four design fixtures exercise the
    /// bracket plan without shipping their Effects).
    nonisolated(unsafe) public static var testSchemas: [String: EffectSchema] = [:]

    // MARK: - Evaluation

    public struct Result {
        public init(image: CIImage, renderedCount: Int, unrecognised: [String]) {
            self.image = image
            self.renderedCount = renderedCount
            self.unrecognised = unrecognised
        }
        public let image: CIImage
        /// How many Effects actually rendered — the bypass counter's
        /// assertion surface: a disabled Effect never increments it.
        public let renderedCount: Int
        /// Ids this build could not render (kept in the stack, reported
        /// in the Inspector).
        public let unrecognised: [String]
    }

    /// Evaluate one ordered stack over one premultiplied input image.
    /// Resolution-parameterized: the tier arrives in the environment and
    /// the INPUT already carries it (the caller decodes at tier) — the
    /// evaluator's job is content, never quality decisions.
    public static func evaluate(stack: [EffectInstance],
                                input: CIImage,
                                keyTracks: [EffectKeyTrack] = [],
                                environment: EffectRenderEnvironment,
                                renderers: [String: EffectRenderer]? = nil) -> Result {
        let known = renderers ?? builtInRenderers
        let unrecognised = stack
            .filter { $0.enabled && known[$0.effectId] == nil }
            .map(\.effectId)

        var image = input
        var rendered = 0
        for batch in batches(for: stack, renderers: renderers) {
            // ONE bracket around the whole run — stage-owned, never per
            // Effect, and only when alpha could be fractional at all.
            if batch.bracketed { image = image.unpremultiplyingAlpha() }
            for instance in batch.instances {
                let schema = EffectSchemaRegistry.schema(for: instance.effectId)
                    ?? testSchemas[instance.effectId]
                let parameters = resolvedParameters(
                    for: instance, schema: schema,
                    keyTracks: keyTracks, environment: environment)
                if let renderer = known[instance.effectId] {
                    image = renderer(image, parameters, environment)
                    rendered += 1
                }
            }
            if batch.bracketed { image = image.premultiplyingAlpha() }
        }
        return Result(image: image, renderedCount: rendered,
                      unrecognised: unrecognised)
    }
}
