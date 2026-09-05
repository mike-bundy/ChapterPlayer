//
//  PlayerResolutionTier.swift
//  ChapterPlayer
//
//  MIRROR of `MaestroKit.PlayerResolutionTier`'s cases (FL-05): the evaluator is
//  resolution-parameterized and the player renders at `.full`. The raw
//  values are the Kit's, so a tier named in a document or a seam test means
//  the same thing on both sides.
//

import Foundation

public enum PlayerResolutionTier: String, CaseIterable, Sendable, Equatable {
    case full, half, quarter

    /// The Kit's sampling factor for the tier: 1, 1/2, 1/4.
    public var factor: Double {
        switch self {
        case .full: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }
}
