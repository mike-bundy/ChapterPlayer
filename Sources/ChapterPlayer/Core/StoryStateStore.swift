//
//  StoryStateStore.swift
//  ChapterPlayer
//
//  THE RUNNING CHAPTER'S MEMORY.
//
//  A reference-typed owner for one `ChapterScript.StoryStateLedger`, so the
//  engine, the gate wait and the navigator all read and write the SAME session
//  rather than passing copies of a value type around and diverging.
//
//  The semantics are not here. What a mutation means, what a condition answers
//  and what resets a session all live in `ChapterScript` — this owns the
//  lifetime and tells anyone who cares that something changed.
//
//  ── A SESSION IS NOT A VISIT ────────────────────────────────────────────────
//
//  `SequenceEngine.play` begins a Sequence VISIT and must never touch this. A
//  CHAPTER PLAYBACK SESSION is the whole run, and it is the only thing that
//  seeds or clears these values. If a visit reset them, walking back into the
//  gallery would forget that the viewer heard the radio.
//
//  ── NOT DOCUMENT STATE ──────────────────────────────────────────────────────
//
//  Nothing here is serialized, synced or undoable. `ChapterDocument.storyState`
//  holds the DEFINITIONS; what a viewer's run has made of them stops when the
//  run does.
//

import Foundation
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "StoryState"
)

@MainActor
@Observable
public final class StoryStateStore {

    /// The current session's values. Read by the condition evaluator directly —
    /// `StoryStateLedger` IS a `StoryStateReading`, so nothing copies it into a
    /// dictionary first.
    public private(set) var ledger = StoryStateLedger()

    /// True between `beginSession` and `endSession`. Distinct from "the ledger
    /// is empty": a Chapter that defines no Story State still has a session.
    public private(set) var isSessionActive = false

    /// Something changed. The gate wait subscribes so a story-condition boundary
    /// resolves the moment the fact it waits for becomes true — event-driven,
    /// never a per-frame poll over the Chapter.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init() {}

    // MARK: - Session lifetime

    /// BEGIN A CHAPTER PLAYBACK SESSION. Every state returns to its authored
    /// initial value.
    public func beginSession(_ definitions: [StoryStateDefinition]) {
        ledger.begin(definitions)
        isSessionActive = true
        if !definitions.isEmpty {
            logger.info("[story] session began with \(definitions.count) Story State(s)")
        }
        onChange?()
    }

    /// END OF SESSION. The run is over; nothing is remembered into the next one.
    public func endSession() {
        guard isSessionActive else { return }
        ledger.end()
        isSessionActive = false
        logger.info("[story] session ended")
        onChange?()
    }

    // MARK: - Mutation

    /// Apply one authored change and tell anyone waiting.
    ///
    /// A refusal is LOGGED, not silently swallowed: a mutation naming a deleted
    /// Story State is an authoring problem, and the only symptom on device would
    /// otherwise be a gate that never opens.
    @discardableResult
    public func apply(_ mutation: StoryStateMutation) -> Bool {
        switch ledger.apply(mutation) {
        case .success(let value):
            logger.info("[story] \(mutation.stateId) is now \(String(describing: value))")
            onChange?()
            return true
        case .failure(let refusal):
            logger.warning("[story] \(refusal.message)")
            return false
        }
    }
}
