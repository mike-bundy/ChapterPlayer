//
//  EffectSchema.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/EffectSchema.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import ChapterScript

// MARK: - Kinds (small and CLOSED — not twelve types)

public enum EffectParameterKind: String, Codable, Sendable, Equatable {
    case scalar          // with a declared range
    case normalized      // 0…1
    case angle           // degrees
    case color
    case point           // normalized; the space is declared
    case boolean
    case choice          // a small enum
    /// A Source the Effect reads (a LUT, a matte) — a FILE reference the
    /// reference walks must see, or the Final Bundle deletes it.
    case sourceReference
    /// An ordered monotone control-point curve (FL-10) — a structured
    /// value; between two curves with different point counts there is no
    /// honest blend, so it is constant-interpolated like every discrete
    /// kind.
    case curve
    /// A mask outline (FL-11) — rectangle, ellipse or Bézier, as a
    /// structured value. Whole-shape transform rides scalar parameters;
    /// the shape itself is constant-interpolated.
    case shape

    /// Discrete kinds are TYPE-ENFORCED to constant interpolation:
    /// nothing can attempt to blend between two enum cases.
    public var supportsInterpolation: Bool {
        switch self {
        case .scalar, .normalized, .angle, .color, .point:
            return true
        case .boolean, .choice, .sourceReference, .curve, .shape:
            return false
        }
    }
}

/// Which clock an animatable parameter reads (FL-13). Source-referenced
/// parameters evaluate at the MAPPED source time and compensate
/// automatically under a retime; timeline-referenced ones do not. Which
/// one it is, is DECLARED.
public enum EffectTimeReference: String, Codable, Sendable, Equatable {
    case timeline
    case source
}

/// The coordinate space a `.point` parameter is declared in.
public enum EffectPointSpace: String, Codable, Sendable, Equatable {
    case source
    case occurrence
}

// MARK: - One parameter

public struct EffectParameterSchema: Sendable, Equatable {
    /// The STABLE identifier — never localized, never shown raw.
    public let key: String
    /// What the author reads. The key never leaks into the UI.
    public let label: String
    public let kind: EffectParameterKind
    public let defaultValue: EffectValue
    /// For `.scalar`: the declared range. Rendering CLAMPS to it; the
    /// stored value is never rewritten.
    public let range: ClosedRange<Double>?
    /// The cases of a `.choice`, as (stable case name, label).
    public let choices: [(key: String, label: String)]
    /// Siblings that move together (a gang id); nil = independent.
    public let gang: String?
    /// Declared per ANIMATABLE parameter (FL-13).
    public let timeReference: EffectTimeReference
    public let pointSpace: EffectPointSpace?

    public init(key: String, label: String, kind: EffectParameterKind,
                defaultValue: EffectValue,
                range: ClosedRange<Double>? = nil,
                choices: [(key: String, label: String)] = [],
                gang: String? = nil,
                timeReference: EffectTimeReference = .timeline,
                pointSpace: EffectPointSpace? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.defaultValue = defaultValue
        self.range = range
        self.choices = choices
        self.gang = gang
        self.timeReference = timeReference
        self.pointSpace = pointSpace
    }

    public static func == (l: EffectParameterSchema, r: EffectParameterSchema) -> Bool {
        l.key == r.key && l.label == r.label && l.kind == r.kind
            && l.defaultValue == r.defaultValue && l.range == r.range
            && l.choices.map(\.key) == r.choices.map(\.key)
            && l.gang == r.gang && l.timeReference == r.timeReference
            && l.pointSpace == r.pointSpace
    }

    /// Clamped FOR RENDERING; the stored value is unchanged. Reports
    /// whether a clamp happened so the Inspector can say so.
    public func renderValue(from stored: EffectValue?) -> (value: EffectValue, clamped: Bool) {
        let value = stored ?? defaultValue
        switch kind {
        case .scalar, .angle:
            if let n = value.numberValue, let range {
                let clamped = min(max(n, range.lowerBound), range.upperBound)
                return (.number(clamped), clamped != n)
            }
        case .normalized:
            if let n = value.numberValue {
                let clamped = min(max(n, 0), 1)
                return (.number(clamped), clamped != n)
            }
        case .choice:
            if let s = value.stringValue, !choices.isEmpty,
               !choices.contains(where: { $0.key == s }) {
                // An unrecognised case renders as the default; stored
                // value untouched (the same weaker-claim discipline).
                return (defaultValue, true)
            }
        case .color, .point, .boolean, .sourceReference, .curve, .shape:
            break
        }
        return (value, false)
    }
}

// MARK: - Projection classes

/// Does the result depend on WHERE the pixel is? Color and blend are
/// projection-independent; transform and screen-space crop/mask are not,
/// and they REFUSE on spherical media with a sentence.
public enum EffectProjectionClass: String, Codable, Sendable, Equatable {
    case projectionIndependent
    case projectionAware
    case destinationAware
}

// MARK: - One Effect's schema

public struct EffectSchema: Sendable, Equatable {
    /// The stable string that `EffectInstance.effectId` names.
    public let effectId: String
    /// What the author reads (the descriptor layer localizes on top).
    public let displayName: String
    public let family: String
    /// FL-04's bracket is owned by the STAGE; this flag is its only
    /// input. The stage unpremultiplies once around the whole run of
    /// Effects that answer yes.
    public let operatesOnColorValues: Bool
    public let projectionClass: EffectProjectionClass
    /// ORDERED — the form renders in this order.
    public let parameters: [EffectParameterSchema]

    public init(effectId: String, displayName: String, family: String,
                operatesOnColorValues: Bool,
                projectionClass: EffectProjectionClass,
                parameters: [EffectParameterSchema]) {
        self.effectId = effectId
        self.displayName = displayName
        self.family = family
        self.operatesOnColorValues = operatesOnColorValues
        self.projectionClass = projectionClass
        self.parameters = parameters
    }

    public func parameter(_ key: String) -> EffectParameterSchema? {
        parameters.first { $0.key == key }
    }

    /// A fresh instance with the schema's defaults — a sensible starting
    /// look, not zeros.
    public func makeInstance() -> EffectInstance {
        EffectInstance(effectId: effectId, parameters: [:])
    }

    /// Which parameters may carry Keys. The schema is the capability
    /// owner for Effect parameters — `KeyframeCapabilities` stays the ten
    /// Object channels' and is untouched.
    public var animatableParameterKeys: [String] {
        parameters.filter { $0.kind.supportsInterpolation }.map(\.key)
    }
}

// MARK: - The registry

/// The known schemas. Flat, family-grouped by the catalog — never
/// visibility lists. FL-10/11/12/14 register here; this campaign ships
/// exactly ONE renderable Effect: the reference no-op that proves the
/// path end to end without prejudicing the schema.
public enum EffectSchemaRegistry {

    /// The reference Effect: a single scalar, mathematically transparent
    /// at its default. Exists to prove drop → stack → form → keys →
    /// evaluate → cache → export without shipping a look.
    public static let referenceEffectId = "maestro.effect.reference"

    public static let reference = EffectSchema(
        effectId: referenceEffectId,
        displayName: "Reference Dial",
        family: "Utility",
        operatesOnColorValues: true,
        projectionClass: .projectionIndependent,
        parameters: [
            EffectParameterSchema(
                key: "amount", label: "Amount", kind: .normalized,
                defaultValue: .number(0), timeReference: .timeline),
        ])

    public static let all: [EffectSchema] = [
        ColorEffect.schema,
        MaskEffect.schema,
        KeyerEffects.chromaSchema,
        KeyerEffects.lumaSchema,
        reference,
    ]

    public static func schema(for effectId: String) -> EffectSchema? {
        all.first { $0.effectId == effectId }
    }

    /// The Inspector's sentence for an Effect this build cannot render.
    public static let unrecognisedNotice =
        "This Effect was made with a newer version of Maestro."
}
