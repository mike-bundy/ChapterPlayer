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
                case .occurrenceReference:
                    // NOT A FILE. An occurrence id names an authored clip
                    // on this Sequence, and the Final Bundle keeps files —
                    // treating this as a filename would have it look for
                    // an asset called "clip_3" and report it missing.
                    // `occurrences(in:)` is the walk that answers for it.
                    break
                case .scalar, .normalized, .angle, .color, .point,
                     .boolean, .choice, .curve, .shape:
                    break
                }
            }
        }
        return out
    }

    /// Every OCCURRENCE a stack references (FL-11's `matteFromClip`).
    ///
    /// A separate walk from `files`, because they answer different
    /// questions for different consumers: the Final Bundle keeps files, and
    /// a delete or a re-id of a clip has to know which masks pointed at it.
    public static func occurrences(in stack: [EffectInstance]) -> [String] {
        var out: [String] = []
        for instance in stack {
            guard let schema = EffectSchemaRegistry.schema(for: instance.effectId) else { continue }
            for parameter in schema.parameters {
                switch parameter.kind {
                case .occurrenceReference:
                    if let id = (instance.parameters[parameter.key]
                        ?? parameter.defaultValue).stringValue, !id.isEmpty {
                        out.append(id)
                    }
                case .scalar, .normalized, .angle, .color, .point, .boolean,
                     .choice, .sourceReference, .curve, .shape:
                    break
                }
            }
        }
        return out
    }
}
