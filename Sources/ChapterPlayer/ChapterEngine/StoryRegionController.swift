//
//  StoryRegionController.swift
//  ChapterPlayer
//
//  EXPLORE, ON DEVICE.
//
//  `ChapterScript.StoryRegionRuntime` is the arithmetic — which region is
//  active, whether its exit resolved, whether the story is playing its first
//  pass or holding at the boundary. This is what that arithmetic touches:
//  the fallback timer, the continuation behaviours, and the one call that
//  releases the story.
//
//  WHAT THIS DELIBERATELY DOES NOT OWN: the hold itself.
//
//  A region's exit is a GATE on the step that ends at its boundary, and the
//  engine already parks `sequenceAnimationTime` at a step's end while a gate
//  waits — animation, audio automation and backdrop cues have held there since
//  gates were wired. So Explore's hold is the mechanism the runtime already
//  had, and this file adds no second way to stop the story. Resolving the exit
//  is `satisfyGate()`, the same call a tap has always made.
//
//  That is also why there is no second detector: the exit is a `StepGate`, so
//  `GateDetectionController` and `SpatialTriggerDetector` do the sensing, and
//  an accessible activation of the same interaction releases the region exactly
//  as a physical one does.
//
//  THE CLOCK THIS OWNS IS THE RUNTIME ONE.
//
//  `elapsed` comes from the engine's own pause-aware playback clock, never from
//  `Date()` and never from a `Task.sleep`. A paused experience does not age its
//  region, and an app that was suspended for a minute does not come back to
//  find the Explore span expired. The fallback timer is polled on that clock
//  rather than scheduled, so there is nothing to cancel and nothing to leak.
//

import Foundation
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "StoryRegions"
)

@MainActor
@Observable
public final class StoryRegionController {

    // MARK: - Wiring

    /// Releases the story. Wired to `SequenceEngine.satisfyGate` — the SAME
    /// call a tap makes, so there is one way out of a hold.
    @ObservationIgnored public var releaseStory: (() -> Void)?

    /// The runtime's pause-aware playback clock, in seconds. Supplied by the
    /// engine (`totalElapsed`), which already subtracts paused time.
    @ObservationIgnored public var runtimeClock: (() -> TimeInterval)?

    /// The authored Sequence clock, which the engine clamps at a boundary
    /// during a gate wait. That clamping IS the hold.
    @ObservationIgnored public var authoredClock: (() -> TimeInterval)?

    /// Applies a continuation behaviour to one target. Wired by
    /// `ChapterPlayerCore` to the executors; nil in tests.
    @ObservationIgnored public var applyContinuation:
        ((StoryContinuationTarget, StoryContinuationBehavior, ContinuationPhase) -> Void)?

    /// Fades one target's gain to silence over N seconds as the story
    /// resumes. Wired to the runtime's existing per-channel gain command —
    /// there is no region-owned gain engine.
    @ObservationIgnored public var applyExitFade:
        ((StoryContinuationTarget, TimeInterval) -> Void)?

    /// Loop overlay for an entity's animation: the sample time an explicitly
    /// looping entity should be evaluated at while the story is held.
    @ObservationIgnored public var setAnimationLoopOverride:
        ((_ entity: String, _ sampleTime: Double?) -> Void)?

    /// When a continuation is applied, and why.
    public enum ContinuationPhase: Sendable, Equatable {
        /// The authored first pass reached the boundary and the story is now
        /// holding. Start whatever was authored to keep going.
        case enteringHold
        /// The region resolved. Put everything back to ordinary evaluation.
        case leavingHold
    }

    // MARK: - Observable state

    /// The region the runtime is inside, if any. Small and changes at most
    /// twice per region, so it is safe to observe.
    public private(set) var active: StoryRegionRuntime?

    /// Seconds the story has been parked at the boundary — what a runtime
    /// indicator shows. Published on CHANGE at a coarse granularity, never per
    /// frame: see `tick`.
    public private(set) var displayDwell: Int = 0

    /// Whether the story is currently held. Drives host UI ("Exploring").
    public private(set) var isHolding: Bool = false

    @ObservationIgnored private var regions: [StoryRegion] = []
    /// Loop overrides installed this hold, so `leavingHold` removes exactly
    /// what `enteringHold` added.
    @ObservationIgnored private var installedLoops: Set<String> = []

    public init() {}

    // MARK: - Sequence lifecycle

    /// Adopt a sequence's authored regions. Called when a Sequence Visit begins.
    public func begin(regions: [StoryRegion]) {
        teardown()
        self.regions = StoryRegionTimeline.sorted(regions)
        if !self.regions.isEmpty {
            logger.info("Sequence has \(self.regions.count) Explore region(s)")
        }
    }

    /// End of visit. Every transient fact goes; nothing here was ever authored.
    public func teardown() {
        clearLoopOverrides()
        regions = []
        active = nil
        isHolding = false
        displayDwell = 0
    }

    // MARK: - The tick

    /// Advance the region state machine.
    ///
    /// Called from the engine's existing timing loop — NOT from a display link
    /// and NOT from a timer of its own. Everything below is O(regions), which
    /// is a handful, and nothing here walks the document, rebuilds a
    /// projection, or issues a media command unless a phase actually changed.
    public func tick() {
        guard !regions.isEmpty,
              let authored = authoredClock?(), let now = runtimeClock?() else { return }

        // ENTERING. Half-open containment, so a boundary belongs to whatever
        // follows and two adjacent regions cannot both claim an instant.
        if active == nil, let entering = StoryRegionTimeline.region(at: authored, in: regions) {
            active = StoryRegionRuntime(region: entering, enteredAtRuntimeTime: now)
            logger.info("Entered Explore region '\(entering.name ?? entering.id)' at \(String(format: "%.2f", authored))s")
        }

        guard var runtime = active else { return }

        // THE FALLBACK TIMER, polled rather than scheduled — measured from
        // region ENTRY, on the pause-aware clock.
        if runtime.applyFallbackIfDue(atRuntimeTime: now) {
            logger.info("Explore region '\(runtime.region.id)' resolved by its fallback timer")
        }

        let phase = runtime.phase(authoredTime: authored)

        // ENTERING THE HOLD: the authored first pass has reached the boundary
        // with the exit unresolved.
        if phase == .held, !isHolding {
            isHolding = true
            applyContinuations(for: runtime.region, phase: .enteringHold)
            logger.info("Explore hold at \(String(format: "%.2f", authored))s — story parked")
        }

        // The loop overlay, for the few targets explicitly authored to loop.
        if isHolding, let sampleTime = runtime.loopSampleTime(authoredTime: authored, atRuntimeTime: now) {
            for entity in installedLoops {
                setAnimationLoopOverride?(entity, sampleTime)
            }
        }

        // RELEASING. The exit resolved (by condition or timer) while held, so
        // the story may go. One call, the same one a tap makes.
        if phase == .resolved || runtime.resolution != nil {
            if isHolding {
                applyContinuations(for: runtime.region, phase: .leavingHold)
                clearLoopOverrides()
                isHolding = false
                displayDwell = 0
                logger.info("Explore region '\(runtime.region.id)' released — resuming Directed playback")
                releaseStory?()
            }
            // Resolved during the FIRST PASS: nothing to release, and nothing
            // to skip. Authored time simply runs to the boundary and out.
        }

        // A DWELL READOUT AT ONE HERTZ, not per tick. It is a label whose text
        // width changes; publishing it at tick rate would invalidate its host
        // several times a second for a number that reads the same.
        if isHolding {
            let whole = Int(runtime.dwell(authoredTime: authored, atRuntimeTime: now))
            if whole != displayDwell { displayDwell = whole }
        }

        active = runtime
    }

    /// The viewer satisfied the exit — a tap, a facing dwell, an approach, a
    /// grab, or an accessible activation of the same interaction.
    ///
    /// Idempotent, and safe during the first pass: it marks the exit satisfied
    /// so the story does not stall when it reaches the boundary, WITHOUT
    /// skipping any authored content in between.
    public func resolveActiveRegion() {
        guard var runtime = active, let now = runtimeClock?() else { return }
        guard runtime.resolution == nil else { return }
        runtime.resolve(.exitCondition, atRuntimeTime: now)
        active = runtime
        logger.info("Explore exit satisfied for '\(runtime.region.id)'")
    }

    /// Playback left the region for a reason outside its own rules.
    public func interruptActiveRegion() {
        guard var runtime = active, let now = runtimeClock?() else { return }
        runtime.resolve(.interrupted, atRuntimeTime: now)
        active = runtime
        clearLoopOverrides()
        isHolding = false
    }

    /// The engine crossed a region's end boundary and moved on. Drops the
    /// active region so the next one can be entered.
    public func regionDidComplete() {
        clearLoopOverrides()
        active = nil
        isHolding = false
        displayDwell = 0
    }

    /// Is the story currently parked in an Explore hold? The engine asks before
    /// letting a boundary gate go.
    public var isHoldingStory: Bool { isHolding }

    /// DOES A STORY REGION OWN THE TIMING OF THE GATE NOW WAITING?
    ///
    /// A region has ONE fallback timer, measured from region entry. The gate
    /// compiled onto its boundary may still carry a `timeout` in a document
    /// authored before that was normalized — and a gate timeout measures from
    /// the moment it starts waiting, so the two would race and the shorter one
    /// would silently win.
    ///
    /// The engine asks this before starting a gate's own timeout. True while a
    /// region is active, because that gate IS the region's exit.
    public var ownsActiveGateTiming: Bool { active != nil }

    // MARK: - Continuations

    private func applyContinuations(for region: StoryRegion, phase: ContinuationPhase) {
        for continuation in region.continuations {
            // AN EXIT FADE IS INDEPENDENT OF THE BEHAVIOUR, so it is handled
            // before the `.hold` early-out: content left on its default can
            // still be authored to fade as the story resumes.
            if phase == .leavingHold, let seconds = continuation.exitFade, seconds > 0 {
                applyExitFade?(continuation.target, seconds)
            }

            // `.hold` is the default and means "do nothing", so there is
            // nothing to apply and nothing to undo.
            guard continuation.behavior != .hold else { continue }

            if case .entityAnimation(let entity) = continuation.target,
               continuation.behavior == .loop {
                switch phase {
                case .enteringHold: installedLoops.insert(entity)
                case .leavingHold:  installedLoops.remove(entity)
                }
            }
            applyContinuation?(continuation.target, continuation.behavior, phase)
        }
    }

    /// Remove every animation loop overlay, returning those entities to
    /// ordinary Sequence evaluation.
    private func clearLoopOverrides() {
        for entity in installedLoops { setAnimationLoopOverride?(entity, nil) }
        installedLoops.removeAll()
    }
}
