//
//  BevelProfiles.swift
//  ChapterPlayer
//
//  THE MIRROR of `MaestroKit.BevelProfileCatalog` (FL-07 / FL-22). The
//  editors and the player cannot share code, so the table and the rule are
//  duplicated verbatim and held together by MaestroVision's
//  `BevelProfileSeamTests`: a profile is a named chamfer resolution; an id
//  this build does not know draws NO bevel and keeps the reference.
//

import Foundation
import RealityKit

enum BevelProfiles {

    /// id → chamfer segments per span. Same ids, same counts as the editor.
    static let segmentsById: [String: Int] = [
        "maestro.bevel.chamfer": 1,
        "maestro.bevel.crisp": 2,
        "maestro.bevel.round": 8,
        "maestro.bevel.soft": 16,
    ]

    enum Resolution: Equatable {
        case platformDefault
        case segments(Int)
        case unresolved
    }

    static func resolve(profileId: String?, segments: Int?) -> Resolution {
        if let id = profileId, !id.isEmpty {
            guard let count = segmentsById[id] else { return .unresolved }
            return .segments(max(1, segments ?? count))
        }
        if let segments { return .segments(max(1, segments)) }
        return .platformDefault
    }
}
