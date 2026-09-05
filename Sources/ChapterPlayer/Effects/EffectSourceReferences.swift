//
//  EffectSourceReferences.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/EffectSourceReferences.swift (FL-09
//  … FL-13 player parity). Change one, change both.
//
import Foundation
import ChapterScript

public enum EffectSourceReferences {

    /// Every file the stack references, known schemas only — an
    /// unrecognised Effect's references are preserved in its raw
    /// parameters and travel with it.
    public static func files(in stack: [EffectInstance]) -> [String] {
        var out: [String] = []
        for instance in stack {
            guard let schema = EffectSchemaRegistry.schema(for: instance.effectId) else { continue }
            for parameter in schema.parameters {
                switch parameter.kind {
                case .sourceReference:
                    if let file = (instance.parameters[parameter.key]
                        ?? parameter.defaultValue).stringValue,
                       !file.isEmpty {
                        out.append(file)
                    }
                case .scalar, .normalized, .angle, .color, .point,
                     .boolean, .choice, .curve, .shape:
                    break
                }
            }
        }
        return out
    }
}
