//
//  SequenceEngine.swift
//  SharedVisions
//
//  Generic step choreographer.
//  Reads SequenceDefinitions and executes StepActions through pluggable executors.
//  Handles timing, pause/resume/skip/goto/restart.
//

import Foundation
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "SequenceEngine"
)

#if DEBUG
/// Step-1 dispatch signposter — marks when the first step's actions begin executing.
/// Paired with SpatialAudioManager's "prewarm_hit" signpost for Instruments profiling.
private let stepSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "AudioPerf"
)
#endif

// MARK: - Status (internal reporting struct)

public struct SequenceStatus: Sendable {
    public let sequenceId: String
    public let stepId: String
    public let stepIndex: Int
    public let stepName: String
    public let stepElapsed: TimeInterval
    public let stepDuration: TimeInterval
    public let totalElapsed: TimeInterval
    public let totalDuration: TimeInterval
    public let totalSteps: Int
    public let isPlaying: Bool
    public let isWaiting: Bool
    public let isComplete: Bool
    public let gateType: String?
    public let waitElapsed: TimeInterval?
    public let masterVolume: Float?
    public let activeZones: Int?
}

@MainActor
@Observable
public final class SequenceEngine {


    public init() {}
    // MARK: - State

    public private(set) var currentSequence: SequenceDefinition?
    public private(set) var currentStepIndex: Int = 0
    public private(set) var isPaused: Bool = false
    public private(set) var isPlaying: Bool = false

    // MARK: - Gate State

    public private(set) var isWaiting: Bool = false
    public private(set) var currentGate: StepGate?
    public private(set) var waitStartTime: Date?

    // MARK: - Timing

    private var stepStartTime: Date = .now
    private var sequenceStartTime: Date = .now
    private var stepPausedDuration: TimeInterval = 0
    private var sequencePausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    // MARK: - Internal

    private var playTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var scheduledActionTasks: [Task<Void, Never>] = []
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateTimeoutTask: Task<Void, Never>?
    /// Advances a HELD Explore region while `waitAtGate` is suspended. See
    /// `waitAtGate`.
    private var exploreTickTask: Task<Void, Never>?

    // MARK: - Executors

    public var entityExecutor: EntityActionExecutorProtocol?
    public var audioExecutor: AudioActionExecutorProtocol?
    public var videoExecutor: VideoActionExecutorProtocol?
    public var attachmentExecutor: AttachmentActionExecutorProtocol?
    public var effectExecutor: EffectActionExecutorProtocol?

    // MARK: - Audio Completion Tracking

    private var audioCompletionActions: [String: [StepAction]] = [:]
    private var completionWired = false

    // MARK: - Callbacks

    /// Called when a step changes — lets AppModel/ImmersiveView react
    public var onStepChanged: ((StepDefinition, Int) -> Void)?
    /// Called when sequence completes
    /// AN AUTHORED NAVIGATION WANTS TO HAPPEN.
    ///
    /// The engine never navigates; it reports. `ChapterPlayerCore` wires this
    /// to `ExperienceNavigator`, so an Interaction's Go To and a Sequence's
    /// completion converge on one authority.
    public var onNavigationRequested: ((NavigationIntent) -> Void)?

    public var onSequenceComplete: ((CompletionAction) -> Void)?
    /// Called to send step status (observers / utility window)
    public var onStatusUpdate: ((SequenceStatus) -> Void)?
    /// Called when a sequence starts playing
    public var onSequenceStarted: ((String) -> Void)?
    /// Called when a gate activates — lets ImmersiveView show a prompt
    public var onGateStarted: ((StepGate) -> Void)?
    /// Called when a gate is satisfied — lets ImmersiveView hide the prompt
    public var onGateEnded: (() -> Void)?

    /// Runtime spatial-gate detection (viewer-facing / proximity / grab). Wired by
    /// `ChapterPlayerCore`; runs alongside `onGateStarted`/`onGateEnded`,
    /// which stay reserved for the consumer's prompt UI.
    public weak var gateDetector: GateDetecting?

    /// Live entity interactions. Wired by `ChapterPlayerCore`. The engine holds
    /// it for exactly two reasons: to dispatch the `enableInteraction` /
    /// `disableInteraction` actions, and to TEAR IT DOWN on every sequence
    /// transition — a watch that survives one would fire Act One's narration
    /// during Act Three.
    public weak var interactionController: InteractionController?

    /// EXPLORE. Wired by `ChapterPlayerCore`. The engine holds it to tick the
    /// region state machine from its own timing loop and to ask, at a boundary
    /// gate, whether an Explore region is still holding the story.
    ///
    /// It does NOT own the hold: a region's exit is a gate on the boundary
    /// step, and the engine has parked `sequenceAnimationTime` at a step's end
    /// during a gate wait since gates were wired. Explore reuses that.
    public weak var storyRegions: StoryRegionController?

    /// WHAT THE CHAPTER REMEMBERS, for this playback session. Wired by
    /// `ChapterPlayerCore`, which owns the session's lifetime.
    ///
    /// The engine holds it for exactly two reasons: to apply a `setStoryState`
    /// action, and to ask a waiting story-condition gate whether the facts it
    /// waits for now hold. It never seeds it and never clears it — `play` begins
    /// a Sequence VISIT, and a visit is not a session.
    public weak var storyState: StoryStateStore?

    /// Follows the sequence's timed backdrop track. Hung off the engine rather
    /// than owned by it: the engine's business is steps, gates and actions,
    /// and a backdrop is none of those. It is driven from the same places the
    /// animation and audio-automation clocks are, so a gate holds a backdrop
    /// cue exactly where it holds a curve.
    public weak var backdropDriver: BackdropCueDriver?

    // MARK: - Computed

    public var currentStep: StepDefinition? {
        guard let sequence = currentSequence,
              currentStepIndex >= 0,
              currentStepIndex < sequence.steps.count else { return nil }
        return sequence.steps[currentStepIndex]
    }

    public var currentSequenceId: String {
        currentSequence?.id ?? ""
    }

    public var currentStepId: String {
        currentStep?.id ?? ""
    }

    public var totalDuration: TimeInterval {
        currentSequence?.totalDuration ?? 0
    }

    public var stepElapsed: TimeInterval {
        guard isPlaying else { return 0 }
        let now = Date.now
        let raw = now.timeIntervalSince(stepStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - stepPausedDuration - activePause
    }

    public var totalElapsed: TimeInterval {
        guard isPlaying else { return 0 }
        let now = Date.now
        let raw = now.timeIntervalSince(sequenceStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - sequencePausedDuration - activePause
    }

    // MARK: - Play

    /// Starts sequence playback. Use `startingAtStepIndex` to skip earlier steps.
    /// Always resets entities, attachments, and effects to their canonical defaults so
    /// switching sequences starts from a clean slate (SharedVisions policy: safe full reset).
    public func play(sequence: SequenceDefinition, startingAtStepIndex startIndex: Int = 0) {
        stop(resetEntities: true)

        currentSequence = sequence
        let stepCount = sequence.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += sequence.steps[i].duration
        }
        sequenceStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing sequence: \(sequence.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", sequence.totalDuration))s total)")

        registerSequenceAnimation(sequence)
        // Re-arm interactions here rather than at each call site: this is the
        // one place every route into a Sequence passes through, and it runs
        // AFTER the `stop()` above, which tore the previous set down.
        interactionController?.reinstall()
        // Explore regions belong to the same Sequence Visit.
        storyRegions?.begin(regions: sequence.storyRegions)
        startStatusReporting()
        onSequenceStarted?(sequence.id)

        logger.notice("▶ play() creating playTask for sequence=\(sequence.id) stepIndex=\(clampedStart)")
        startPlayTask(sequence: sequence, startIndex: clampedStart)
    }

    /// Async variant: runs the step loop in the caller's Task context instead of
    /// creating a new fire-and-forget Task. Use from auto-advance chains.
    /// Always resets entities/attachments/effects (SharedVisions policy).
    public func playAndAwait(sequence: SequenceDefinition, startingAtStepIndex startIndex: Int = 0) async -> CompletionAction? {
        stop(resetEntities: true)

        currentSequence = sequence
        let stepCount = sequence.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += sequence.steps[i].duration
        }
        sequenceStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing sequence (await): \(sequence.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", sequence.totalDuration))s total)")

        registerSequenceAnimation(sequence)
        // Re-arm interactions here rather than at each call site: this is the
        // one place every route into a Sequence passes through, and it runs
        // AFTER the `stop()` above, which tore the previous set down.
        interactionController?.reinstall()
        // Explore regions belong to the same Sequence Visit.
        storyRegions?.begin(regions: sequence.storyRegions)
        startStatusReporting()
        onSequenceStarted?(sequence.id)

        return await runStepsFrom(index: clampedStart, in: sequence)
    }

    /// Hand the sequence's animation tracks to the entity executor, clocked
    /// by the authored sequence time so gates/pauses hold curves in place.
    private func registerSequenceAnimation(_ sequence: SequenceDefinition) {
        entityExecutor?.setSequenceAnimation(
            tracks: sequence.animationTracks,
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 }
        )
        // Audio volume rides on the SAME authored clock, so a gate holds a
        // fade exactly where it holds a transform curve.
        audioExecutor?.setSequenceAudioAutomation(
            tracks: sequence.audioTracks,
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 },
            // AUTHORED FADES travel with the automation, because they are the
            // same question: how loud is this clip right now. Gathered once
            // per sequence start — a document walk, never a per-frame one.
            fades: Self.authoredFades(in: sequence)
        )
        // Backdrop cues ride the SAME authored clock. On wall time a viewer
        // held at a gate would watch the backdrop cut ahead of the step they
        // are still waiting on.
        backdropDriver?.begin(
            track: sequence.backdropTrack,
            legacy: sequence.immersiveBackdrop,
            presentation: sequence.presentation,
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 }
        )
    }

    /// Every channel's authored fades, gathered once when a sequence starts.
    ///
    /// `SequenceDefinition` is the runtime's own shape, so this rebuilds the
    /// DTO view `AudioGainComposition.fades(forChannel:in:)` expects — one
    /// walk, at sequence start, never on a frame.
    static func authoredFades(in sequence: SequenceDefinition) -> [String: [AudioFade]] {
        var channels: Set<String> = []
        var stepStart = 0.0
        var result: [String: [AudioFade]] = [:]
        for step in sequence.steps {
            // Both buckets: an immediate action fires at the step's start, a
            // scheduled one at its own offset.
            let timed: [(Double, StepAction)] =
                step.actions.map { (stepStart, $0) }
                + step.scheduledActions.map { (stepStart + $0.at, $0.action) }
            for (time, action) in timed {
                switch action {
                case .playAudio(let a):
                    channels.insert(a.channel)
                    if let fadeIn = a.fadeIn, fadeIn > 0 {
                        result[a.channel, default: []].append(
                            AudioFade(startTime: time, duration: fadeIn, to: a.volume, from: 0)
                        )
                    }
                case .fadeAudio(let channel, let to, let duration):
                    channels.insert(channel)
                    result[channel, default: []].append(
                        AudioFade(startTime: time, duration: duration, to: to)
                    )
                default:
                    break
                }
            }
            stepStart += step.duration
        }
        for channel in result.keys {
            result[channel]?.sort { $0.startTime < $1.startTime }
        }
        return result
    }

    /// The authored sequence clock: absolute seconds along the sequence's
    /// step grid — the domain animation-track keys live in. Unlike
    /// `totalElapsed` (wall time minus pauses), this clock stops at a
    /// gated step's end and never drifts when gates stretch real time.
    public var sequenceAnimationTime: TimeInterval {
        guard let sequence = currentSequence, isPlaying else { return 0 }
        let index = max(0, min(currentStepIndex, sequence.steps.count - 1))
        var start: TimeInterval = 0
        for i in 0..<index { start += sequence.steps[i].duration }
        let stepDuration = sequence.steps.indices.contains(index) ? sequence.steps[index].duration : 0
        return start + min(max(stepElapsed, 0), stepDuration)
    }

    // MARK: - Stop

    public func stop(resetEntities: Bool = true, fullReset: Bool = false) {
        if playTask != nil {
            logger.notice("⏹ stop() cancelling playTask for sequence=\(self.currentSequenceId) resetEntities=\(resetEntities) fullReset=\(fullReset)")
        }
        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        stopStatusReporting()
        // Stop following cues, but leave the backdrop standing: a sequence SWAP
        // stops the old engine before the new sequence applies its own cue
        // zero, and blanking in between is a black flash between sequences.
        // A full reset is the case that genuinely wants it gone.
        backdropDriver?.stop(tearDown: fullReset)
        isPaused = false
        isPlaying = false
        stepPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil
        resumeIfPaused()
        clearGate()

        // Clear audio completion tracking
        audioCompletionActions.removeAll()
        completionWired = false
        audioExecutor?.onChannelFinished = nil

        if fullReset {
            audioExecutor?.stopEverything()
        } else {
            audioExecutor?.stopAll()
        }
        videoExecutor?.stopAll()
        entityExecutor?.setSequenceAnimation(tracks: [], clock: nil)
        // TEARDOWN IS NOT OPTIONAL. Every play path begins with `stop`, so this
        // is the one place that guarantees no facing poll, proximity poll or
        // manipulation subscription outlives the Sequence that armed it — and
        // that a `.once` interaction is spent for the RUN, not forever.
        interactionController?.teardown()
        // A region's dwell, its loop overlays and its fallback timer are all
        // visit state. Stop ends the visit, so they all go.
        storyRegions?.teardown()

        cleanup(resetEntities: resetEntities)
    }

    private func cleanup(resetEntities: Bool) {
        attachmentExecutor?.hideAll()
        effectExecutor?.resetAllEffects()
        if resetEntities {
            entityExecutor?.resetAllEntities()
        }
    }

    // MARK: - Transport Controls

    public func pause() {
        guard !isPaused, isPlaying else { return }
        isPaused = true
        pauseStartTime = .now
        audioExecutor?.pauseAll()
        videoExecutor?.pauseAll()
        effectExecutor?.pauseAll()
        sendStatus()
        logger.info("Paused")
    }

    public func resume() {
        guard isPaused else { return }
        if let start = pauseStartTime {
            let elapsed = Date.now.timeIntervalSince(start)
            stepPausedDuration += elapsed
            sequencePausedDuration += elapsed
        }
        pauseStartTime = nil
        isPaused = false
        audioExecutor?.resumeAll()
        videoExecutor?.resumeAll()
        effectExecutor?.resumeAll()
        resumeIfPaused()
        sendStatus()
        logger.info("Resumed")
    }

    public func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    public func skip() {
        guard let sequence = currentSequence else { return }
        let nextIndex = currentStepIndex + 1
        guard nextIndex < sequence.steps.count else {
            logger.info("Already at last step — cannot skip")
            return
        }
        jumpToStep(index: nextIndex)
    }

    public func previous() {
        guard currentStepIndex > 0 else {
            logger.info("Already at first step — cannot go previous")
            return
        }
        jumpToStep(index: currentStepIndex - 1)
    }

    public func jumpToStep(_ stepId: String) {
        guard let sequence = currentSequence,
              let index = sequence.steps.firstIndex(where: { $0.id == stepId }) else {
            logger.warning("Unknown step ID: \(stepId)")
            return
        }
        jumpToStep(index: index)
    }

    public func jumpToStep(index: Int) {
        guard let sequence = currentSequence,
              index >= 0, index < sequence.steps.count else { return }

        logger.info("Jumping to step index \(index): \(sequence.steps[index].id)")

        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        resumeIfPaused()
        clearGate()
        isPaused = false
        stepPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        audioExecutor?.stopAll()
        videoExecutor?.stopAll()
        cleanup(resetEntities: true)

        var elapsed: TimeInterval = 0
        for i in 0..<index {
            elapsed += sequence.steps[i].duration
        }
        sequenceStartTime = Date.now.addingTimeInterval(-elapsed)

        isPlaying = true
        // Re-register the sequence's animation tracks: a natural completion
        // deregisters them, so a jump after completion (or after stop)
        // must restore per-frame track sampling like play() does.
        registerSequenceAnimation(sequence)
        startStatusReporting()

        startPlayTask(sequence: sequence, startIndex: index)
    }

    public func restart() {
        guard let sequence = currentSequence else { return }
        play(sequence: sequence)
    }

    // MARK: - Step Loop

    /// Shared step-iteration loop used by play(), jumpToStep(), and playAndAwait().
    /// Returns the sequence completion only when playback reaches its natural end.
    private func runStepsFrom(index startIndex: Int, in sequence: SequenceDefinition) async -> CompletionAction? {
        let stepCount = sequence.steps.count
        logger.notice("▶ runStepsFrom: sequence=\(sequence.id) startIndex=\(startIndex) stepCount=\(stepCount) isCancelled=\(Task.isCancelled)")

        for index in startIndex..<stepCount {
            let step = sequence.steps[index]
            guard !Task.isCancelled else {
                logger.warning("⚠️ Sequence \(sequence.id) cancelled at step \(step.id) — playTask was cancelled before step could start")
                return nil
            }

            currentStepIndex = index
            stepStartTime = .now
            stepPausedDuration = 0
            logger.info("Step → \(step.id) (\(step.name), \(String(format: "%.1f", step.duration))s)")

            // Per-frame motion curves are scoped to a single step. Clearing here means
            // the previous step's `.animateMotion` actions stop affecting entities
            // before this step's own actions run (and may register fresh ones).
            entityExecutor?.clearAllMotions()

            await executeActions(step.actions)
            let actionsElapsed = Date.now.timeIntervalSince(stepStartTime)
            logger.info("executeActions: \(String(format: "%.3f", actionsElapsed))s for step \(step.id)")
            onStepChanged?(step, index)
            sendStatus()

            // Scheduled actions fire inline within the timing loop — no fire-and-forget
            // Tasks. On visionOS, MainActor Task scheduling is starved by RealityKit GPU
            // resource prep, so fire-and-forget Tasks for scheduled actions never execute.
            //
            // SORTED CURSOR, NOT A RESCAN. This used to walk every scheduled
            // action on every 250 ms tick and test a Set for whether it had
            // already fired — O(actions) four times a second, on the main
            // actor, forever. Timeline 3.0 makes Steps longer and fewer (they
            // are runtime pause regions now, not editorial containers), so a
            // feature-length sequence can put hundreds of actions in one Step
            // and that scan becomes the hot path.
            //
            // Fires in TIME order, ties broken by authored order — which is
            // also what `MaestroKit.SequenceTime.actionsInAbsoluteOrder` does,
            // so the editor and the runtime agree on what happens first.
            let scheduledInFireOrder = step.scheduledActions
                .enumerated()
                .sorted { a, b in
                    a.element.at != b.element.at ? a.element.at < b.element.at
                                                 : a.offset < b.offset
                }
                .map(\.element)
            var nextScheduled = 0

            // An action stored past its Step's end can never fire: this loop
            // exits while it is still pending, silently. Say so rather than
            // letting authored behaviour vanish without a word.
            for scheduled in scheduledInFireOrder where scheduled.at > step.duration {
                let detail = "step '\(step.id)': action scheduled at +"
                    + String(format: "%.2f", scheduled.at) + "s but the step is only "
                    + String(format: "%.2f", step.duration)
                    + "s long — it will NEVER fire. The document is malformed."
                logger.error("\(detail, privacy: .public)")
            }

            var remaining = max(0, step.duration - Date.now.timeIntervalSince(stepStartTime))
            // `repeat`, not `while`: a ZERO-DURATION step starts with
            // `remaining == 0`, so a plain `while` never entered the body and
            // anything scheduled at +0 in such a step never fired. Running the
            // body once drains the due actions and then exits on the same
            // condition, so nothing changes for a step with real duration.
            repeat {
                guard !Task.isCancelled else { return nil }

                if isPaused {
                    sendStatus()
                    await withCheckedContinuation { continuation in
                        pauseContinuation = continuation
                    }
                    pauseContinuation = nil
                    sendStatus()
                }

                let elapsedSinceStepStart = Date.now.timeIntervalSince(stepStartTime) - stepPausedDuration
                while nextScheduled < scheduledInFireOrder.count,
                      elapsedSinceStepStart >= scheduledInFireOrder[nextScheduled].at {
                    let scheduled = scheduledInFireOrder[nextScheduled]
                    nextScheduled += 1
                    logger.info("Scheduled action fired at +\(String(format: "%.1f", scheduled.at))s in step \(step.id)")
                    if scheduled.action.isAsync {
                        await executeAction(scheduled.action)
                    } else {
                        executeActionSync(scheduled.action)
                    }
                }

                // EXPLORE runs on the loop that already exists. No display
                // link, no second timer, no `Date` arithmetic of its own — the
                // controller reads the engine's pause-aware clock, so a paused
                // experience does not age its region.
                storyRegions?.tick()

                let sleepTime = min(remaining, 0.25)
                try? await Task.sleep(for: .seconds(sleepTime))
                remaining = max(0, step.duration - Date.now.timeIntervalSince(stepStartTime))
            } while remaining > 0

            if let gate = step.gate {
                guard !Task.isCancelled else { return nil }

                if isPaused {
                    await withCheckedContinuation { continuation in
                        pauseContinuation = continuation
                    }
                    pauseContinuation = nil
                }

                await waitAtGate(gate)
            }

            // A REGION ENDING AT THIS BOUNDARY HAS NOW BEEN RELEASED.
            //
            // The gate above is the region's exit, so reaching here means it
            // was satisfied — by the viewer, by the region's fallback timer, or
            // by the gate's own timeout. Drop the active region so the next one
            // can be entered, and so a second region starting at this exact
            // boundary is not mistaken for the one just left.
            storyRegions?.regionDidComplete()
        }

        guard !Task.isCancelled else { return nil }

        logger.info("Sequence \(sequence.id) complete")

        if case .holdOnLastStep = sequence.onComplete {
            sendStatus(isComplete: true)
        } else {
            isPlaying = false
            stopStatusReporting()
            sendStatus(playing: false)
            // Deregister the sequence's animation tracks: with isPlaying
            // false the animation clock reads 0, so a still-registered
            // track would slam every keyed entity back to its t=0 pose on
            // the next per-frame sample. Entities keep the final sampled
            // transforms; a subsequent play/jump re-registers.
            entityExecutor?.setSequenceAnimation(tracks: [], clock: nil)
        }

        return sequence.onComplete
    }

    private func startPlayTask(sequence: SequenceDefinition, startIndex: Int) {
        playTask = Task { @MainActor in
            guard let completion = await self.runStepsFrom(index: startIndex, in: sequence) else { return }
            self.onSequenceComplete?(completion)
        }
    }

    // MARK: - Gate

    /// Satisfy the active gate, resuming playback.
    public func satisfyGate() {
        guard isWaiting else { return }
        logger.info("Gate satisfied")
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
        exploreTickTask?.cancel()
        exploreTickTask = nil
        isWaiting = false
        currentGate = nil
        waitStartTime = nil
        onGateEnded?()
        gateContinuation?.resume()
        gateContinuation = nil
        if isPaused {
            resume()
        }
        sendStatus()
    }

    /// THE STORY'S MEMORY CHANGED — does a waiting boundary continue now?
    ///
    /// Called after every applied mutation, from wherever it arrived: a step
    /// action, an Interaction response, a response nested in `onAudioComplete`.
    ///
    /// Only a `.storyCondition` gate is released here. A gate that asked for an
    /// ACT still needs the act — "tap the door once you have the key" is not
    /// opened by finding the key, and turning it into that would silently make
    /// the tap decorative.
    public func storyStateDidChange() {
        guard isWaiting, let gate = currentGate, let store = storyState else { return }
        guard GateActivation.satisfiedByStory(gate.authored, in: store.ledger) else { return }
        logger.info("[gate] satisfied by what the story remembers")
        satisfyGate()
    }

    /// Wait at a gate, respecting pause. Returns when gate is satisfied or task cancelled.
    private func waitAtGate(_ gate: StepGate) async {
        // A GATE ASKS "IS THIS TRUE?", NOT "DID THIS JUST HAPPEN".
        //
        // So a story-condition boundary whose facts ALREADY hold does not stall
        // at all — the same reasoning that keeps a proximity GATE on
        // `.immediate` arming while a proximity INTERACTION waits for an entry
        // edge. Checked BEFORE the wait is set up, because satisfying a gate
        // whose continuation does not exist yet would suspend forever.
        if let store = storyState,
           GateActivation.satisfiedByStory(gate.authored, in: store.ledger) {
            logger.info("[gate] story conditions already hold; the boundary does not stall")
            return
        }

        isWaiting = true
        currentGate = gate
        waitStartTime = .now
        logger.info("Gate activated: \(gate.type.rawValue), timeout=\(gate.timeout.map { String($0) } ?? "none")")

        sendStatus()
        onGateStarted?(gate)
        gateDetector?.gateDidStart(gate) { [weak self] in
            self?.satisfyGate()
        }

        // A STORY REGION OWNS ITS OWN TIMING. Its fallback runs from region
        // ENTRY on the pause-aware clock; a gate timeout would run from HERE,
        // on a `Task.sleep`, and the two would race. Ordinary Step gates are
        // untouched — this only skips the gate timer when the gate IS a
        // region's exit.
        let regionOwnsTiming = storyRegions?.ownsActiveGateTiming == true
        if regionOwnsTiming, gate.timeout != nil {
            logger.info("[explore] ignoring the exit gate's own timeout — the Story Region's fallback owns this region's timing")
        }
        if let timeout = gate.timeout, !regionOwnsTiming {
            gateTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self.satisfyGate()
            }
        }

        // EXPLORE'S PUMP WHILE THE STORY IS PARKED.
        //
        // `waitAtGate` suspends on a continuation, so the step loop's tick is
        // not running — yet a held region still has to advance its dwell,
        // poll its fallback timer and drive its loop overlays. This is that
        // pump, and it is cancelled with the gate.
        //
        // Four times a second, matching the step loop's own cadence. It reads a
        // clock and compares a handful of regions; it never walks the document,
        // rebuilds a projection or issues a media command unless a phase
        // actually changed.
        if storyRegions?.active != nil {
            exploreTickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.storyRegions?.tick()
                }
            }
        }

        await withCheckedContinuation { continuation in
            gateContinuation = continuation
        }
        gateContinuation = nil
    }

    private func clearGate() {
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
        exploreTickTask?.cancel()
        exploreTickTask = nil
        isWaiting = false
        currentGate = nil
        waitStartTime = nil
        onGateEnded?()
        gateContinuation?.resume()
        gateContinuation = nil
    }

    // MARK: - Scheduled Actions

    private func cancelScheduledActions() {
        for task in scheduledActionTasks {
            task.cancel()
        }
        scheduledActionTasks.removeAll()
    }

    // MARK: - Action Execution

    /// Test-only entry point — allows unit tests to verify action routing deterministically.
    public func testExecuteAction(_ action: StepAction) async {
        await executeAction(action)
    }

    /// RUN A RESPONSE THAT DID NOT COME FROM A STEP.
    ///
    /// An entity interaction fires when the VIEWER acts, not when the clock
    /// reaches a second — but what it runs is an ordinary action list, so it
    /// goes through the ordinary dispatch. That is the whole point: there is no
    /// second action engine, and `playAudio` means one thing in this app.
    ///
    /// Deliberately independent of step context: it does not advance, pause,
    /// satisfy a gate or touch `currentStepIndex`. An interaction leaves the
    /// story exactly where it was.
    public func performActions(_ actions: [StepAction]) {
        guard !actions.isEmpty else { return }
        Task { @MainActor in await self.executeActions(actions) }
    }

    private func executeActions(_ actions: [StepAction]) async {
#if DEBUG
        if currentStepIndex == 0 {
            stepSignposter.emitEvent("step1_dispatch")
        }
#endif
        for action in actions {
            if action.isAsync {
                await executeAction(action)
            } else {
                executeActionSync(action)
            }
        }
    }

    /// Async action dispatch — for actions where the executor is actually async.
    private func executeAction(_ action: StepAction) async {
        switch action {
        // No async actions in the default SharedVisions action set; extend here as needed.
        default:
            executeActionSync(action)
        }
    }

    /// Synchronous action dispatch — no suspension points.
    private func executeActionSync(_ action: StepAction) {
        switch action {
        // Entity
        case .showEntity(let name):
            entityExecutor?.showEntity(named: name)
        case .hideEntity(let name):
            entityExecutor?.hideEntity(named: name)
        case .moveEntity(let moveAction):
            entityExecutor?.moveEntity(moveAction)
        case .scaleEntity(let name, let multiplier, let duration, let timing):
            entityExecutor?.scaleEntity(named: name, multiplier: multiplier, duration: duration, timing: timing)
        case .fadeEntity(let fadeAction):
            entityExecutor?.fadeEntity(fadeAction)
        case .revealEntity(let revealAction):
            entityExecutor?.revealEntity(revealAction)
        case .animateMotion(let motion):
            entityExecutor?.beginMotion(motion)
        case .motionBehavior(let behavior):
            entityExecutor?.beginMotionBehavior(behavior)
        case .persistEntity(let name):
            entityExecutor?.persistEntity(named: name)
        case .unpersistEntity(let name):
            entityExecutor?.unpersistEntity(named: name)

        // Attachments
        case .showAttachment(let id):
            attachmentExecutor?.show(attachmentId: id)
        case .hideAttachment(let id):
            attachmentExecutor?.hide(attachmentId: id)
        case .fadeAttachment(let id, let opacity, let duration):
            attachmentExecutor?.fade(attachmentId: id, opacity: opacity, duration: duration)
        case .setAttachmentView(let id, let viewId):
            attachmentExecutor?.setView(attachmentId: id, viewId: viewId)
        case .positionAttachment:
            // Attachment positioning is a no-op in the default SharedVisions build.
            // Extend EffectActionExecutor or AttachmentActionExecutor to implement.
            break

        // Audio
        case .playAudio(let audioAction):
            audioExecutor?.play(audioAction, stepContext: "\(currentSequenceId)/\(currentStepId)")
        case .stopAudio(let channel):
            audioExecutor?.stop(channel: channel)
        case .fadeAudio(let channel, let to, let duration):
            audioExecutor?.fade(channel: channel, to: to, duration: duration)

        // Video
        case .playVideo(let videoAction):
            videoExecutor?.play(videoAction)
        case .prepareVideo(let videoAction):
            videoExecutor?.prepare(videoAction)
        case .stopVideo(let channel):
            videoExecutor?.stop(channel: channel)

        // Effects
        case .showPulseRing(let config):
            effectExecutor?.showPulseRing(config: config)
        case .hidePulseRing:
            effectExecutor?.hidePulseRing()
        case .startSparkBurst(let config):
            effectExecutor?.startSparkBurst(config: config)
        case .stopSparkBurst:
            effectExecutor?.stopSparkBurst()

        // Audio Mix
        case .setMasterVolume(let volume):
            audioExecutor?.setMasterVolume(volume)
        case .setCategoryVolume(let category, let volume):
            audioExecutor?.setCategoryVolume(category: category, volume: volume)

        // Audio Completion
        case .onAudioComplete(let channel, let actions):
            wireAudioCompletion()
            audioCompletionActions[channel] = actions

        // Audio Zones
        case .addAudioZone(let zone):
            audioExecutor?.addAudioZone(zone)
        case .removeAudioZone(let id):
            audioExecutor?.removeAudioZone(id: id)
        case .removeAllAudioZones:
            audioExecutor?.removeAllAudioZones()

        // Audio Bus
        case .setBusVolume(let busId, let volume):
            audioExecutor?.setBusVolume(busId: busId, volume: volume)
        case .setBusEffect(let busId, let effect):
            audioExecutor?.setBusEffect(busId: busId, effect: effect)
        case .removeBusEffect(let busId, let effect):
            audioExecutor?.removeBusEffect(busId: busId, effect: effect)

        // Gesture control
        case .enableGesture(let entity):
            entityExecutor?.enableGesture(named: entity)
        case .disableGesture(let entity):
            entityExecutor?.disableGesture(named: entity)

        // Interaction control. Routed to the interaction controller rather
        // than an executor: an interaction is not a property of an entity's
        // RENDERING, it is a live registration.
        case .enableInteraction(let entity, let id):
            interactionController?.setInteraction(id, on: entity, enabled: true)
        case .disableInteraction(let entity, let id):
            interactionController?.setInteraction(id, on: entity, enabled: false)

        case .navigate(let intent):
            // THE ENGINE DOES NOT NAVIGATE. It reports the authored intent and
            // the host hands it to `ExperienceNavigator` — the same authority a
            // completion goes through. An engine that started Sequences itself
            // would be the second navigator this architecture removed.
            //
            // Deliberately fire-and-report: the current Sequence is left as-is
            // here, and the navigator decides whether it is suspended (Go To)
            // or discarded (Restart / End). Tearing down from inside a step
            // dispatch would race the very playback issuing it.
            logger.info("[flow] authored navigation requested: \(String(describing: intent))")
            onNavigationRequested?(intent)

        case .setStoryState(let mutation):
            // THE ENGINE DOES NOT OWN THE MEMORY. It hands the change to the
            // session's store, which applies the shared arithmetic and then
            // notifies — and that notification is what re-asks a waiting
            // story-condition gate. ONE path, so a mutation applied from
            // anywhere else (a host, a future action) releases a boundary too.
            storyState?.apply(mutation)

        // System UI — no-ops at this level (wire in SharedVisionsApp if needed)
        case .setUpperLimbVisibility, .setKeyboardPassthrough:
            break

        // Custom
        case .custom(let id):
            logger.info("Custom action: \(id)")
            effectExecutor?.handleCustomAction(id: id)
        }
    }

    // MARK: - Audio Completion Wiring

    private func wireAudioCompletion() {
        guard !completionWired else { return }
        completionWired = true
        audioExecutor?.onChannelFinished = { [weak self] channel in
            guard let self else { return }
            if let actions = self.audioCompletionActions.removeValue(forKey: channel) {
                logger.info("Audio complete on '\(channel)' — executing \(actions.count) follow-up action(s)")
                Task { @MainActor in
                    await self.executeActions(actions)
                }
            }
        }
    }

    // MARK: - Status Reporting

    private func sendStatus(playing: Bool? = nil, isComplete: Bool = false) {
        guard let sequence = currentSequence, let step = currentStep else { return }

        let status = SequenceStatus(
            sequenceId: sequence.id,
            stepId: step.id,
            stepIndex: currentStepIndex,
            stepName: step.name,
            stepElapsed: stepElapsed,
            stepDuration: step.duration,
            totalElapsed: totalElapsed,
            totalDuration: totalDuration,
            totalSteps: sequence.steps.count,
            isPlaying: playing ?? (isPlaying && !isPaused),
            isWaiting: isWaiting,
            isComplete: isComplete,
            gateType: currentGate?.type.rawValue,
            waitElapsed: waitStartTime.map { Date.now.timeIntervalSince($0) },
            masterVolume: audioExecutor?.currentMasterVolume,
            activeZones: audioExecutor?.activeZoneCount
        )

        onStatusUpdate?(status)
    }

    private func startStatusReporting() {
        stopStatusReporting()
        statusTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0))
                guard !Task.isCancelled else { break }
                if !isPaused {
                    sendStatus()
                }
            }
        }
    }

    private func stopStatusReporting() {
        statusTask?.cancel()
        statusTask = nil
    }

    // MARK: - Private

    private func resumeIfPaused() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}
