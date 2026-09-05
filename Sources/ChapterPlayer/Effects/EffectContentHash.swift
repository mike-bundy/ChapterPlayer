//
//  EffectContentHash.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/EffectContentHash.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import ChapterScript

public enum EffectContentHash {

    /// A stable 64-bit FNV-1a over the evaluation-relevant content.
    /// Deliberately NOT `Hasher` (its seed changes per process, and this
    /// key may live in a per-Chapter disk tier validated by content).
    public static func hash(_ stack: [EffectInstance]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
        }
        func mix(_ s: String) { mix(s.utf8); mix([0]) }

        for instance in stack where instance.enabled {
            mix(instance.effectId)
            // Sorted keys: dictionary order is not identity.
            for key in instance.parameters.keys.sorted() {
                mix(key)
                mix(canonical(instance.parameters[key]!))
            }
            mix([0xFF]) // instance boundary — order is part of the hash
        }
        return h
    }

    static func canonical(_ value: EffectValue) -> String {
        switch value {
        case .number(let n): return "n:\(n)"
        case .bool(let b): return "b:\(b)"
        case .string(let s): return "s:\(s)"
        case .raw(let fragment): return "r:" + canonical(fragment)
        }
    }

    static func canonical(_ fragment: JSONFragment) -> String {
        switch fragment {
        case .null: return "0"
        case .bool(let b): return "b\(b)"
        case .number(let n): return "n\(n)"
        case .string(let s): return "s\(s.utf8.count):\(s)"
        case .array(let a): return "[" + a.map(canonical).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\($0)=" + canonical(o[$0]!) }
                .joined(separator: ",") + "}"
        }
    }
}
