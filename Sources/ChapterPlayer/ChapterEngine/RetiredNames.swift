//
//  RetiredNames.swift
//  ChapterPlayer
//
//  API-COMPAT. The runtime's old word for a Segment was retired on 2026-10-10
//  (docs/TERMINOLOGY.md in chapterengine). Apps that build against this
//  package's `main` (the SharedVisions player) still call these names, so they
//  forward to the new ones as deprecated, with `renamed:` fix-its. Delete this
//  file once no client calls them. Nothing else may use these names.
//

import Foundation

extension SequenceDefinition {
    @available(*, deprecated, renamed: "segments")  // API-COMPAT
    public var steps: [SegmentDefinition] { segments }  // API-COMPAT
}

@MainActor
extension SequenceEngine {
    @available(*, deprecated, renamed: "currentSegmentIndex")  // API-COMPAT
    public var currentStepIndex: Int { currentSegmentIndex }  // API-COMPAT

    @available(*, deprecated, renamed: "segmentElapsed")  // API-COMPAT
    public var stepElapsed: TimeInterval { segmentElapsed }  // API-COMPAT

    @available(*, deprecated, renamed: "jumpToSegment(index:)")  // API-COMPAT
    public func jumpToStep(index: Int) { jumpToSegment(index: index) }  // API-COMPAT

    @available(*, deprecated, renamed: "play(sequence:startingAtSegmentIndex:)")  // API-COMPAT
    public func play(sequence: SequenceDefinition, startingAtStepIndex index: Int) {  // API-COMPAT
        play(sequence: sequence, startingAtSegmentIndex: index)
    }
}

@MainActor
extension EntityActionExecutor {
    @available(*, deprecated, renamed: "applyActiveMotions(segmentElapsed:totalElapsed:)")  // API-COMPAT
    public func applyActiveMotions(stepElapsed: TimeInterval, totalElapsed: TimeInterval) {  // API-COMPAT
        applyActiveMotions(segmentElapsed: stepElapsed, totalElapsed: totalElapsed)  // API-COMPAT
    }
}
