//
//  StepTimingFunction+Animation.swift
//  SharedVisions
//
//  Maps StepTimingFunction (data layer) to RealityKit's AnimationTimingFunction.
//  Kept in its own file so ChapterDefinition stays a pure data layer (no RealityKit import).
//

import RealityKit

extension StepTimingFunction {
    /// Convert to RealityKit's animation timing function for entity animations.
    public var animationTimingFunction: AnimationTimingFunction {
        switch self {
        case .linear:    return .linear
        case .easeIn:    return .easeIn
        case .easeOut:   return .easeOut
        case .easeInOut: return .easeInOut
        }
    }
}
