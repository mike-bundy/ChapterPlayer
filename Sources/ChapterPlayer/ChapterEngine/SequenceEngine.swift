//
//  SequenceEngine.swift
//  SharedVisions
//
//  Generic segment choreographer.
//  Reads SequenceDefinitions and executes SegmentActions through pluggable executors.
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
/// Segment-1 dispatch signposter — marks when the first segment's actions begin executing.
/// Paired with SpatialAudioManager's "prewarm_hit" signpost for Instruments profiling.
private let segmentSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "AudioPerf"
)
#endif

// MARK: - Status (internal reporting struct)

public struct SequenceStatus: Sendable {
    public let sequenceId: String
    public let segmentId: String
    public let segmentIndex: Int
    public let segmentName: String
    public let segmentElapsed: TimeInterval
    public let segmentDuration: TimeInterval
    public let totalElapsed: TimeInterval
    public let totalDuration: TimeInterval
    public let totalSegments: Int
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
    public private(set) var currentSegmentIndex: Int = 0
    /// The offset into the current Segment of the action being fired — 0 for
    /// a Segment's immediate actions, `at` for a scheduled one. Read by the
    /// video stamp so an occurrence knows where it starts.
    private var currentFiringOffset: TimeInterval = 0
    /// The Sequence time a seek is landing on, while its late actions are
    /// still being fired; nil the rest of the time. See `alignToSeek`.
    private var catchingUpTo: TimeInterval?
    public private(set) var isPaused: Bool = false
    public private(set) var isPlaying: Bool = false

    // MARK: - Gate State

    public private(set) var isWaiting: Bool = false
    public private(set) var currentGate: SegmentGate?
    public private(set) var waitStartTime: Date?

    // MARK: - Timing

    private var segmentStartTime: Date = .now
    private var sequenceStartTime: Date = .now
    private var segmentPausedDuration: TimeInterval = 0
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

    private var audioCompletionActions: [String: [SegmentAction]] = [:]
    private var completionWired = false

    // MARK: - Callbacks

    /// Called when a segment changes — lets AppModel/ImmersiveView react
    public var onSegmentChanged: ((SegmentDefinition, Int) -> Void)?
    /// Called when sequence completes
    /// AN AUTHORED NAVIGATION WANTS TO HAPPEN.
    ///
    /// The engine never navigates; it reports. `ChapterPlayerCore` wires this
    /// to `ExperienceNavigator`, so an Interaction's Go To and a Sequence's
    /// completion converge on one authority.
    public var onNavigationRequested: ((NavigationIntent) -> Void)?

    public var onSequenceComplete: ((CompletionAction) -> Void)?
    /// Called to send segment status (observers / utility window)
    public var onStatusUpdate: ((SequenceStatus) -> Void)?
    /// Called when a sequence starts playing
    public var onSequenceStarted: ((String) -> Void)?
    /// Called when a gate activates — lets ImmersiveView show a prompt
    public var onGateStarted: ((SegmentGate) -> Void)?
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
    /// segment, and the engine has parked `sequenceAnimationTime` at a segment's end
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
    /// than owned by it: the engine's business is segments, gates and actions,
    /// and a backdrop is none of those. It is driven from the same places the
    /// animation and audio-automation clocks are, so a gate holds a backdrop
    /// cue exactly where it holds a curve.
    public weak var backdropDriver: BackdropCueDriver?
    /// The Sequence this one's completion would lead to, for warming its
    /// first Clips; nil when it leads nowhere. THE HOST'S ANSWER, because where
    /// a completion leads is the navigator's decision and this engine does not
    /// read completions for itself (`sequence_reference_audit`).
    public var followingSequenceProvider: (() -> SequenceDefinition?)?
    /// The caption follower (FL-08) — same relationship as the backdrop
    /// driver: hangs off the engine, is not part of it.
    public weak var captionDriver: CaptionCueDriver?
    /// KEYED MATERIALS (FL-14). Weak and optional exactly as the caption and
    /// backdrop drivers are: a host that never paints animated materials
    /// pays for none of it.
    public weak var materialKeyDriver: MaterialKeyDriver?
    /// Keyed stored USD parts, on the same authored Sequence clock.
    public weak var subElementKeyDriver: SubElementKeyDriver?
    public weak var subElementActionExecutor: (any SubElementActionExecuting)?
    /// The Sequence's material key tracks. A provider rather than a field
    /// because the tracks live on the DTO the host holds, and the engine
    /// works in its own runtime shapes.
    public var materialKeyTracksProvider: (() -> [MaterialKeyTrack]?)?
    public var subElementKeyTracksProvider: (() -> [SubElementKeyTrack]?)?
    /// The Chapter's entity definitions, for the stored overrides a keyed
    /// channel rests on.
    public var entityDefinitionsProvider: (() -> [EntityDefinition])?
    /// The Chapter's caption style library, resolved by the host — the
    /// engine knows Sequences, not the whole document.
    public var captionStylesProvider: (() -> [CaptionStyle]?)?

    // MARK: - Computed

    public var currentSegment: SegmentDefinition? {
        guard let sequence = currentSequence,
              currentSegmentIndex >= 0,
              currentSegmentIndex < sequence.segments.count else { return nil }
        return sequence.segments[currentSegmentIndex]
    }

    public var currentSequenceId: String {
        currentSequence?.id ?? ""
    }

    public var currentSegmentId: String {
        currentSegment?.id ?? ""
    }

    public var totalDuration: TimeInterval {
        currentSequence?.totalDuration ?? 0
    }

    public var segmentElapsed: TimeInterval {
        guard isPlaying else { return 0 }
        let now = Date.now
        let raw = now.timeIntervalSince(segmentStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - segmentPausedDuration - activePause
    }

    public var totalElapsed: TimeInterval {
        guard isPlaying else { return 0 }
        let now = Date.now
        let raw = now.timeIntervalSince(sequenceStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - sequencePausedDuration - activePause
    }

    // MARK: - Play

    /// Starts sequence playback. Use `startingAtSegmentIndex` to skip earlier segments.
    /// Always resets entities, attachments, and effects to their canonical defaults so
    /// switching sequences starts from a clean slate (SharedVisions policy: safe full reset).
    public func play(sequence: SequenceDefinition, startingAtSegmentIndex startIndex: Int = 0) {
        stop(resetEntities: true)

        currentSequence = sequence
        let segmentCount = sequence.segments.count
        let clampedStart = max(0, min(startIndex, segmentCount > 0 ? segmentCount - 1 : 0))
        currentSegmentIndex = clampedStart
        isPaused = false
        isPlaying = true
        segmentPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += sequence.segments[i].duration
        }
        sequenceStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing sequence: \(sequence.id) from segment index \(clampedStart)/\(segmentCount) (\(String(format: "%.1f", sequence.totalDuration))s total)")

        // THE HOST LEARNS WHICH SEQUENCE THIS IS BEFORE ANYTHING IS PRESENTED
        // FOR IT. `registerSequenceAnimation` begins the backdrop and caption
        // drivers, and a backdrop presented while the host still held the
        // previous Sequence's id (nil on a first play) was stamped with that
        // id: its USDZ finished loading, failed the "is this still the
        // Sequence that asked" check, and was thrown away. A first play of any
        // Sequence with a USDZ Environment showed no Environment at all.
        onSequenceStarted?(sequence.id)
        registerSequenceAnimation(sequence)
        // Re-arm interactions here rather than at each call site: this is the
        // one place every route into a Sequence passes through, and it runs
        // AFTER the `stop()` above, which tore the previous set down.
        interactionController?.reinstall()
        // Explore regions belong to the same Sequence Visit.
        storyRegions?.begin(regions: sequence.storyRegions)
        startStatusReporting()

        logger.notice("▶ play() creating playTask for sequence=\(sequence.id) segmentIndex=\(clampedStart)")
        startPlayTask(sequence: sequence, startIndex: clampedStart)
    }

    /// Async variant: runs the segment loop in the caller's Task context instead of
    /// creating a new fire-and-forget Task. Use from auto-advance chains.
    /// Always resets entities/attachments/effects (SharedVisions policy).
    public func playAndAwait(sequence: SequenceDefinition, startingAtSegmentIndex startIndex: Int = 0) async -> CompletionAction? {
        stop(resetEntities: true)

        currentSequence = sequence
        let segmentCount = sequence.segments.count
        let clampedStart = max(0, min(startIndex, segmentCount > 0 ? segmentCount - 1 : 0))
        currentSegmentIndex = clampedStart
        isPaused = false
        isPlaying = true
        segmentPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += sequence.segments[i].duration
        }
        sequenceStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing sequence (await): \(sequence.id) from segment index \(clampedStart)/\(segmentCount) (\(String(format: "%.1f", sequence.totalDuration))s total)")

        // THE HOST LEARNS WHICH SEQUENCE THIS IS BEFORE ANYTHING IS PRESENTED
        // FOR IT. `registerSequenceAnimation` begins the backdrop and caption
        // drivers, and a backdrop presented while the host still held the
        // previous Sequence's id (nil on a first play) was stamped with that
        // id: its USDZ finished loading, failed the "is this still the
        // Sequence that asked" check, and was thrown away. A first play of any
        // Sequence with a USDZ Environment showed no Environment at all.
        onSequenceStarted?(sequence.id)
        registerSequenceAnimation(sequence)
        // Re-arm interactions here rather than at each call site: this is the
        // one place every route into a Sequence passes through, and it runs
        // AFTER the `stop()` above, which tore the previous set down.
        interactionController?.reinstall()
        // Explore regions belong to the same Sequence Visit.
        storyRegions?.begin(regions: sequence.storyRegions)
        startStatusReporting()

        return await runSegmentsFrom(index: clampedStart, in: sequence)
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
            fades: Self.authoredFades(in: sequence),
            muted: Set(sequence.mutedDestinations)
        )
        audioExecutor?.setTrackGains(sequence.trackGains)
        // FL-18: authored duckers map onto the ducking machinery the
        // runtime has always run - dB depth to a linear multiplier,
        // attack/release to the existing fade durations. Explicit and
        // named; nothing implicit is inferred.
        audioExecutor?.setDuckingRules(sequence.duckers.map { spec in
            DuckingRule(trigger: spec.triggerDestinationId,
                        targets: [DuckTarget(
                            channel: spec.targetDestinationId,
                            duckLevel: pow(10, spec.depthDB / 20),
                            fadeInDuration: spec.attack,
                            fadeOutDuration: spec.release)])
        })
        // Backdrop cues ride the SAME authored clock. On wall time a viewer
        // held at a gate would watch the backdrop cut ahead of the segment they
        // are still waiting on.
        backdropDriver?.begin(
            track: sequence.backdropTrack,
            legacy: sequence.immersiveBackdrop,
            presentation: sequence.presentation,
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 }
        )
        // Captions ride the SAME authored clock: a viewer held at a gate
        // keeps reading the caption that belongs to the moment they are
        // held in (FL-08).
        captionDriver?.begin(
            tracks: sequence.captionTracks,
            styles: captionStylesProvider?(),
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 }
        )
        // Keyed materials ride the SAME authored clock, for the same reason
        // (FL-14): a viewer held at a gate sees the paint that belongs to
        // the moment they are held in, not a color that ran ahead on wall
        // time while the story waited for them.
        materialKeyDriver?.begin(
            tracks: materialKeyTracksProvider?(),
            entities: entityDefinitionsProvider?() ?? [],
            clock: { [weak self] in self?.sequenceAnimationTime ?? 0 }
        )
        subElementKeyDriver?.begin(
            tracks: subElementKeyTracksProvider?(),
            entities: entityDefinitionsProvider?() ?? [],
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
        var segmentStart = 0.0
        var result: [String: [AudioFade]] = [:]
        for segment in sequence.segments {
            // Both buckets: an immediate action fires at the segment's start, a
            // scheduled one at its own offset.
            let timed: [(Double, SegmentAction)] =
                segment.actions.map { (segmentStart, $0) }
                + segment.scheduledActions.map { (segmentStart + $0.at, $0.action) }
            for (time, action) in timed {
                switch action {
                case .playAudio(let a):
                    channels.insert(a.channel)
                    // FL-18 N12: the clip's two ramps, FITTED together by
                    // the shared rule so an author who dragged both handles
                    // past the middle hears them meet rather than one of
                    // them silently winning. Same arithmetic as the editor's
                    // — `MediaFadeCurve.fitted` is the one place it lives.
                    let clipEnd = segmentStart + Self.audioOccurrenceEnd(
                        channel: a.channel, firedAt: time - segmentStart, in: segment)
                    let ramps = MediaFadeCurve.fitted(fadeIn: a.fadeIn,
                                                      fadeOut: a.fadeOut,
                                                      span: clipEnd - time)
                    if ramps.in > 0 {
                        result[a.channel, default: []].append(
                            AudioFade(startTime: time, duration: ramps.in, to: a.volume, from: 0)
                        )
                    }
                    if ramps.out > 0 {
                        result[a.channel, default: []].append(
                            AudioFade(startTime: clipEnd - ramps.out, duration: ramps.out,
                                      to: 0, from: a.volume)
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
            segmentStart += segment.duration
        }
        for channel in result.keys {
            result[channel]?.sort { $0.startTime < $1.startTime }
        }
        return result
    }

    /// Where an AUDIO occurrence ends inside its Segment (FL-18 N12).
    ///
    /// The same rule `occurrenceSpan` applies to picture, said once for
    /// sound: the channel's next stop or play LATER in the Segment, else the
    /// Segment's end. A fade-out that ends at the wrong instant is audible,
    /// so this is stated rather than approximated by the clip's media
    /// length — which is a different fact and often longer.
    static func audioOccurrenceEnd(channel: String, firedAt offset: TimeInterval,
                                   in segment: SegmentDefinition) -> TimeInterval {
        var end = segment.duration
        let timed: [(TimeInterval, SegmentAction)] =
            segment.actions.map { (0, $0) } + segment.scheduledActions.map { ($0.at, $0.action) }
        for (at, action) in timed where at > offset + 1e-6 && at < end {
            switch action {
            case .stopAudio(let c) where c == channel: end = at
            case .playAudio(let a) where a.channel == channel: end = at
            default: break
            }
        }
        return max(offset, end)
    }

    /// The authored sequence clock: absolute seconds along the sequence's
    /// segment grid — the domain animation-track keys live in. Unlike
    /// `totalElapsed` (wall time minus pauses), this clock stops at a
    /// gated segment's end and never drifts when gates stretch real time.
    public var sequenceAnimationTime: TimeInterval {
        guard let sequence = currentSequence, isPlaying else { return 0 }
        let index = max(0, min(currentSegmentIndex, sequence.segments.count - 1))
        var start: TimeInterval = 0
        for i in 0..<index { start += sequence.segments[i].duration }
        let segmentDuration = sequence.segments.indices.contains(index) ? sequence.segments[index].duration : 0
        return start + min(max(segmentElapsed, 0), segmentDuration)
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
        captionDriver?.stop(tearDown: fullReset)
        materialKeyDriver?.stop(tearDown: fullReset)
        subElementKeyDriver?.stop(tearDown: fullReset)
        isPaused = false
        isPlaying = false
        catchingUpTo = nil
        segmentPausedDuration = 0
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
            segmentPausedDuration += elapsed
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
        let nextIndex = currentSegmentIndex + 1
        guard nextIndex < sequence.segments.count else {
            logger.info("Already at last segment — cannot skip")
            return
        }
        jumpToSegment(index: nextIndex)
    }

    public func previous() {
        guard currentSegmentIndex > 0 else {
            logger.info("Already at first segment — cannot go previous")
            return
        }
        jumpToSegment(index: currentSegmentIndex - 1)
    }

    public func jumpToSegment(_ segmentId: String) {
        guard let sequence = currentSequence,
              let index = sequence.segments.firstIndex(where: { $0.id == segmentId }) else {
            logger.warning("Unknown segment ID: \(segmentId)")
            return
        }
        jumpToSegment(index: index)
    }

    public func jumpToSegment(index: Int) {
        guard let sequence = currentSequence,
              index >= 0, index < sequence.segments.count else { return }

        logger.info("Jumping to segment index \(index): \(sequence.segments[index].id)")

        tearDownForRelocation()

        var elapsed: TimeInterval = 0
        for i in 0..<index {
            elapsed += sequence.segments[i].duration
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

    /// What a move WITHIN the running Sequence tears down, said once for
    /// `jumpToSegment` and `seek(toSequenceTime:)`: the segment loop, any wait it
    /// was parked in, every sounding channel, and the scene back to its
    /// canonical defaults. Narrower than `stop()` on purpose — the Sequence
    /// Visit continues, so interactions, Explore regions and the cue drivers
    /// are not torn down here.
    private func tearDownForRelocation() {
        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        resumeIfPaused()
        clearGate()
        isPaused = false
        segmentPausedDuration = 0
        sequencePausedDuration = 0
        pauseStartTime = nil

        catchingUpTo = nil

        audioExecutor?.stopAll()
        videoExecutor?.stopAll()
        cleanup(resetEntities: true)
    }

    /// Fire one action from an EARLIER Segment as part of a seek.
    ///
    /// The ordinary dispatch, minus the two things that are events rather
    /// than state. A `navigate` the audience had already passed did not take
    /// them away — they are here — and replaying it would leave the Sequence
    /// being sought in. A spark burst is a one-shot that ended long ago.
    ///
    /// `setStoryState` IS replayed: a later story-condition gate waits on
    /// what an earlier Segment remembered, and a seek past the Segment that
    /// set it would otherwise park the story for good.
    private func preFire(_ action: SegmentAction) {
        switch action {
        case .navigate, .startSparkBurst:
            return
        default:
            // Synchronous on purpose: `executeAction` has no async case today
            // and falls through to this same dispatch.
            executeActionSync(action)
        }
    }

    /// Move a video that a seek started LATE onto the media time the seek
    /// implies. Called from the one place a video play is dispatched, so the
    /// earlier Segments' pre-fire and the target Segment's first due-check
    /// cannot disagree; outside a seek `catchingUpTo` is nil and this does
    /// nothing.
    ///
    /// Plain occurrences only. A retimed one is driven from the authored
    /// clock by its own surface and needs no help; a looping one would need
    /// the media's length, which the engine never has.
    private func alignToSeek(_ video: VideoAction) {
        guard let seekTime = catchingUpTo, let (_, start) = firingSegment,
              video.retime?.isIdentity ?? true, !video.loop else { return }
        let into = seekTime - (start + currentFiringOffset)
        guard into > 0 else { return }
        videoExecutor?.seek(channel: video.channel, to: (video.sourceIn ?? 0) + into)
    }

    /// The media plays a seek must NOT start, as positions in the pre-fire
    /// order (every earlier Segment's immediate actions, then its scheduled
    /// ones in fire order).
    ///
    /// A play that the same channel later stops or replaces, still before
    /// the seek time, leaves nothing behind — but firing it anyway spins up a
    /// player and sounds a first buffer before the stop lands. The target
    /// Segment's own actions up to the offset count as "later" here, because
    /// the segment loop fires them immediately after.
    static func supersededMediaPlays(before target: (index: Int, offset: TimeInterval),
                                     in sequence: SequenceDefinition) -> Set<Int> {
        var lastAudioPlay: [String: Int] = [:]
        var lastVideoPlay: [String: Int] = [:]
        var superseded: Set<Int> = []
        var position = 0

        func visit(_ action: SegmentAction, counted: Bool) {
            switch action {
            case .playAudio(let audio):
                if let earlier = lastAudioPlay[audio.channel] { superseded.insert(earlier) }
                lastAudioPlay[audio.channel] = counted ? position : nil
            case .stopAudio(let channel):
                if let earlier = lastAudioPlay.removeValue(forKey: channel) { superseded.insert(earlier) }
            case .playVideo(let video):
                if let earlier = lastVideoPlay[video.channel] { superseded.insert(earlier) }
                lastVideoPlay[video.channel] = counted ? position : nil
            case .prepareVideo(let video):
                // A preheat is for a play still to come. Track it like a
                // play so one whose play has already been and gone is dropped.
                if let earlier = lastVideoPlay[video.channel] { superseded.insert(earlier) }
                lastVideoPlay[video.channel] = counted ? position : nil
            case .stopVideo(let channel):
                if let earlier = lastVideoPlay.removeValue(forKey: channel) { superseded.insert(earlier) }
            default:
                break
            }
        }

        for index in 0..<target.index {
            let segment = sequence.segments[index]
            for action in segment.actions + scheduledInFireOrder(segment).map(\.action) {
                visit(action, counted: true)
                position += 1
            }
        }
        if sequence.segments.indices.contains(target.index) {
            let segment = sequence.segments[target.index]
            let due = segment.actions
                + scheduledInFireOrder(segment).filter { $0.at <= target.offset }.map(\.action)
            for action in due { visit(action, counted: false) }
        }
        return superseded
    }

    public func restart() {
        guard let sequence = currentSequence else { return }
        play(sequence: sequence)
    }

    // MARK: - Seek

    /// Where a Sequence time lands: the Segment that contains it and the
    /// offset into that Segment. Half-open, so a boundary belongs to the
    /// Segment that FOLLOWS it — the same rule Explore regions use. A time
    /// at or past the Sequence's end lands at the END of the last Segment, so
    /// everything authored has fired and the completion follows naturally.
    public static func seekTarget(for time: TimeInterval,
                                  in sequence: SequenceDefinition) -> (index: Int, offset: TimeInterval)? {
        guard !sequence.segments.isEmpty else { return nil }
        let clamped = max(0, time)
        var start: TimeInterval = 0
        for (index, segment) in sequence.segments.enumerated() {
            if clamped < start + segment.duration { return (index, clamped - start) }
            start += segment.duration
        }
        let last = sequence.segments.count - 1
        return (last, sequence.segments[last].duration)
    }

    /// A Segment's scheduled actions in the order they fire: by time, ties
    /// broken by authored order. The segment loop and the seek pre-fire both
    /// read this, so a seek cannot replay a Segment in a different order than
    /// playing through it would have.
    static func scheduledInFireOrder(_ segment: SegmentDefinition) -> [ScheduledAction] {
        segment.scheduledActions
            .enumerated()
            // The same rule as the editor (ChapterScript `FireOrder`): one
            // instant to the microsecond, and a stop before a start at a cut.
            .sorted { a, b in
                FireOrder.precedes(at: a.element.at, closes: a.element.action.endsAnOccurrence,
                                   offset: a.offset,
                                   before: b.element.at, closes: b.element.action.endsAnOccurrence,
                                   offset: b.offset)
            }
            .map(\.element)
    }

    /// SEEK TO A TIME, NOT TO A BOUNDARY.
    ///
    /// `jumpToSegment` can only land on a Segment's start, and it lands there
    /// with a freshly reset scene — everything earlier Segments revealed is
    /// gone. A seek applies the state the audience WOULD have at `time`:
    /// every earlier Segment's actions fire, in order, then the target
    /// Segment's up to the offset, and the target Segment plays on from
    /// there.
    ///
    /// The earlier Segments are pre-fired HERE, synchronously, so the reset
    /// scene and the restored one land in the same frame. The target
    /// Segment's own actions are not: the segment loop starts with its clock
    /// already at the offset, so its first due-check fires exactly the
    /// actions authored at or before it, through the one cursor that then
    /// goes on to fire the rest. Nothing can fire twice because nothing has
    /// a second path to fire on.
    ///
    /// Gates on earlier Segments are treated as satisfied. Everything
    /// sampled from the authored clock — animation tracks, motion behaviors,
    /// audio automation, backdrop, captions, keyed materials and parts —
    /// needs no pre-fire at all; it reads the new time on its next sample.
    ///
    /// WHAT A PRE-FIRED ACTION CANNOT DO is arrive part-way through its own
    /// duration: a `moveEntity` or a fade authored before `time` starts its
    /// tween at the seek, and AUDIO starts from the top of its source range,
    /// because the audio executor has no initial-offset entry. Video does
    /// have `seek(channel:to:)`, so a plain occurrence is moved to the media
    /// time the seek implies.
    public func seek(toSequenceTime time: TimeInterval) {
        guard let sequence = currentSequence,
              let target = Self.seekTarget(for: time, in: sequence) else { return }

        logger.info("Seeking to \(String(format: "%.2f", time))s: segment index \(target.index) +\(String(format: "%.2f", target.offset))s")

        tearDownForRelocation()
        // A seek can leave an Explore region without passing its exit. Drop
        // it; the next tick enters whichever region holds the new time.
        storyRegions?.regionDidComplete()

        var targetStart: TimeInterval = 0
        for i in 0..<target.index { targetStart += sequence.segments[i].duration }
        let seekTime = targetStart + target.offset
        sequenceStartTime = Date.now.addingTimeInterval(-seekTime)

        isPlaying = true
        registerSequenceAnimation(sequence)
        catchingUpTo = seekTime

        let superseded = Self.supersededMediaPlays(before: target, in: sequence)
        var position = 0
        for index in 0..<target.index {
            let segment = sequence.segments[index]
            currentSegmentIndex = index
            segmentStartTime = .now
            entityExecutor?.clearSegmentMotions()
            let timed: [(TimeInterval, SegmentAction)] =
                segment.actions.map { (0, $0) }
                + Self.scheduledInFireOrder(segment).map { (min($0.at, segment.duration), $0.action) }
            for (at, action) in timed {
                defer { position += 1 }
                guard !superseded.contains(position) else { continue }
                // PARK THE AUTHORED CLOCK ON THE ACTION'S OWN INSTANT. The
                // video stamp and a motion's `startedAt` both read it, so a
                // move authored ten seconds ago is ten seconds into its
                // progress rather than starting now.
                segmentStartTime = Date.now.addingTimeInterval(-at)
                currentFiringOffset = at
                preFire(action)
            }
        }

        // Leave the clock ON the seek time, not on the last pre-fired
        // action: a frame can sample it before the segment loop's Task starts.
        currentSegmentIndex = target.index
        segmentStartTime = Date.now.addingTimeInterval(-target.offset)
        currentFiringOffset = 0
        startStatusReporting()
        startPlayTask(sequence: sequence, startIndex: target.index, startOffset: target.offset)
    }

    // MARK: - Segment Loop

    /// Shared segment-iteration loop used by play(), jumpToSegment(), and playAndAwait().
    /// Returns the sequence completion only when playback reaches its natural end.
    ///
    /// `startOffset` is a seek's: the FIRST Segment run begins with its clock
    /// already that far in, so its first due-check fires everything authored
    /// at or before the offset, in order, and the cursor carries on from
    /// there. Every later Segment starts at zero as it always has.
    private func runSegmentsFrom(index startIndex: Int, in sequence: SequenceDefinition,
                              startOffset: TimeInterval = 0) async -> CompletionAction? {
        let segmentCount = sequence.segments.count
        logger.notice("▶ runSegmentsFrom: sequence=\(sequence.id) startIndex=\(startIndex) segmentCount=\(segmentCount) isCancelled=\(Task.isCancelled)")

        for index in startIndex..<segmentCount {
            let segment = sequence.segments[index]
            guard !Task.isCancelled else {
                logger.warning("⚠️ Sequence \(sequence.id) cancelled at segment \(segment.id) — playTask was cancelled before segment could start")
                return nil
            }

            currentSegmentIndex = index
            let enteredAt = index == startIndex ? max(0, min(startOffset, segment.duration)) : 0
            segmentStartTime = Date.now.addingTimeInterval(-enteredAt)
            segmentPausedDuration = 0
            logger.info("Segment → \(segment.id) (\(segment.name), \(String(format: "%.1f", segment.duration))s)")

            // Per-frame motion curves are scoped to a single segment. Clearing here means
            // the previous segment's `.animateMotion` actions stop affecting entities
            // before this segment's own actions run (and may register fresh ones).
            //
            // MOTION ACTIONS 2.0 BEHAVIORS ARE NOT SEGMENT-SCOPED and are not
            // cleared here — they are timed on the authored sequence clock and
            // saturate on their own. `clearSegmentMotions()` carries the whole
            // reasoning; a Sequence teardown still clears everything through
            // `resetAllEntities()`.
            entityExecutor?.clearSegmentMotions()

            currentFiringOffset = 0
            await executeActions(segment.actions)
            let actionsElapsed = Date.now.timeIntervalSince(segmentStartTime) - enteredAt
            logger.info("executeActions: \(String(format: "%.3f", actionsElapsed))s for segment \(segment.id)")
            onSegmentChanged?(segment, index)
            sendStatus()

            // Scheduled actions fire inline within the timing loop — no fire-and-forget
            // Tasks. On visionOS, MainActor Task scheduling is starved by RealityKit GPU
            // resource prep, so fire-and-forget Tasks for scheduled actions never execute.
            //
            // SORTED CURSOR, NOT A RESCAN. This used to walk every scheduled
            // action on every 250 ms tick and test a Set for whether it had
            // already fired — O(actions) four times a second, on the main
            // actor, forever. Timeline 3.0 makes Segments longer and fewer (they
            // are runtime pause regions now, not editorial containers), so a
            // feature-length sequence can put hundreds of actions in one Segment
            // and that scan becomes the hot path.
            //
            // Fires in TIME order, ties broken by authored order — which is
            // also what `MaestroKit.SequenceTime.actionsInAbsoluteOrder` does,
            // so the editor and the runtime agree on what happens first.
            let scheduledInFireOrder = Self.scheduledInFireOrder(segment)
            var nextScheduled = 0

            // An action stored past its Segment's end is late, not lost: the
            // boundary drain below fires it. Say so, because the document is
            // still malformed and the author's timing is not what they wrote.
            for scheduled in scheduledInFireOrder where scheduled.at > segment.duration {
                let detail = "segment '\(segment.id)': action scheduled at +"
                    + String(format: "%.2f", scheduled.at) + "s but the segment is only "
                    + String(format: "%.2f", segment.duration)
                    + "s long. It fires at the segment's end instead. The document is malformed."
                logger.error("\(detail, privacy: .public)")
            }

            // ONE CLOCK. The fire test below is pause-aware
            // (`- segmentPausedDuration`) and this exit test was not, so after a
            // pause of P seconds the segment ended P seconds early on the action
            // clock and everything authored in that window was dropped.
            func timeLeft() -> Double {
                max(0, segment.duration - (Date.now.timeIntervalSince(segmentStartTime) - segmentPausedDuration))
            }
            var remaining = timeLeft()
            // `repeat`, not `while`: a ZERO-DURATION segment starts with
            // `remaining == 0`, so a plain `while` never entered the body and
            // anything scheduled at +0 in such a segment never fired. Running the
            // body once drains the due actions and then exits on the same
            // condition, so nothing changes for a segment with real duration.
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

                let elapsedSinceSegmentStart = Date.now.timeIntervalSince(segmentStartTime) - segmentPausedDuration
                while nextScheduled < scheduledInFireOrder.count,
                      elapsedSinceSegmentStart >= scheduledInFireOrder[nextScheduled].at {
                    let scheduled = scheduledInFireOrder[nextScheduled]
                    nextScheduled += 1
                    let lateMs = (Date.now.timeIntervalSince(segmentStartTime) - segmentPausedDuration - scheduled.at) * 1000
                    logger.notice("[timing] action at +\(String(format: "%.3f", scheduled.at))s fired \(String(format: "%.0f", lateMs)) ms late (segment \(segment.id, privacy: .public))")
                    currentFiringOffset = scheduled.at
                    if scheduled.action.isAsync {
                        await executeAction(scheduled.action)
                    } else {
                        executeActionSync(scheduled.action)
                    }
                }

                // A seek's late actions have all fired by the end of the
                // first due-check; anything after this starts on time.
                catchingUpTo = nil

                // EXPLORE runs on the loop that already exists. No display
                // link, no second timer, no `Date` arithmetic of its own — the
                // controller reads the engine's pause-aware clock, so a paused
                // experience does not age its region.
                storyRegions?.tick()

                // WAKE FOR THE NEXT ACTION, NOT FOR THE NEXT QUARTER SECOND.
                // The due check runs when this sleep returns, so a fixed
                // 250 ms sleep fired every timed action somewhere between on
                // time and a quarter second late, at a phase that differed on
                // every playback: a cut authored at 3.833 s landed anywhere
                // up to 4.083 s, and no two runs of a Sequence matched. The
                // housekeeping cadence (status, Explore) stays the ceiling.
                var sleepTime = min(remaining, 0.25)
                if nextScheduled < scheduledInFireOrder.count {
                    let now = Date.now.timeIntervalSince(segmentStartTime) - segmentPausedDuration
                    sleepTime = min(sleepTime, max(0.002, scheduledInFireOrder[nextScheduled].at - now))
                }
                try? await Task.sleep(for: .seconds(sleepTime))
                remaining = timeLeft()
            } while remaining > 0

            // THE BOUNDARY DRAIN. The due check sits at the TOP of the body
            // and the loop exits after its final sleep WITHOUT running it
            // again, so the whole last tick was a dead zone: anything
            // authored in the final quarter second of a Segment, or exactly
            // at its end, never fired, silently, on every Chapter. Fire what
            // is left, in order, before the gate waits and before the next
            // Segment begins. It cannot double-fire: `nextScheduled` is this
            // Segment's own cursor and only ever advances.
            while nextScheduled < scheduledInFireOrder.count {
                guard !Task.isCancelled else { return nil }
                let scheduled = scheduledInFireOrder[nextScheduled]
                nextScheduled += 1
                logger.info("Scheduled action fired at the boundary of segment \(segment.id) (authored at +\(String(format: "%.2f", scheduled.at))s of \(String(format: "%.2f", segment.duration))s)")
                currentFiringOffset = min(scheduled.at, segment.duration)
                if scheduled.action.isAsync {
                    await executeAction(scheduled.action)
                } else {
                    executeActionSync(scheduled.action)
                }
            }

            if let gate = segment.gate {
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

        if case .holdOnLastSegment = sequence.onComplete {
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

    private func startPlayTask(sequence: SequenceDefinition, startIndex: Int,
                               startOffset: TimeInterval = 0) {
        playTask = Task { @MainActor in
            guard let completion = await self.runSegmentsFrom(
                index: startIndex, in: sequence, startOffset: startOffset) else { return }
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
    /// Called after every applied mutation, from wherever it arrived: a segment
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
    private func waitAtGate(_ gate: SegmentGate) async {
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
        // on a `Task.sleep`, and the two would race. Ordinary Segment gates are
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
        // `waitAtGate` suspends on a continuation, so the segment loop's tick is
        // not running — yet a held region still has to advance its dwell,
        // poll its fallback timer and drive its loop overlays. This is that
        // pump, and it is cancelled with the gate.
        //
        // Four times a second, matching the segment loop's own cadence. It reads a
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
    public func testExecuteAction(_ action: SegmentAction) async {
        await executeAction(action)
    }

    /// RUN A RESPONSE THAT DID NOT COME FROM A SEGMENT.
    ///
    /// An entity interaction fires when the VIEWER acts, not when the clock
    /// reaches a second — but what it runs is an ordinary action list, so it
    /// goes through the ordinary dispatch. That is the whole point: there is no
    /// second action engine, and `playAudio` means one thing in this app.
    ///
    /// Deliberately independent of segment context: it does not advance, pause,
    /// satisfy a gate or touch `currentSegmentIndex`. An interaction leaves the
    /// story exactly where it was.
    public func performActions(_ actions: [SegmentAction]) {
        guard !actions.isEmpty else { return }
        Task { @MainActor in await self.executeActions(actions) }
    }

    private func executeActions(_ actions: [SegmentAction]) async {
#if DEBUG
        if currentSegmentIndex == 0 {
            segmentSignposter.emitEvent("segment1_dispatch")
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

    // MARK: - Occurrence stamps (FL-12 / FL-13)

    /// The current Segment, when one is playing.
    private var firingSegment: (segment: SegmentDefinition, start: TimeInterval)? {
        guard let sequence = currentSequence,
              sequence.segments.indices.contains(currentSegmentIndex) else { return nil }
        var start: TimeInterval = 0
        for i in 0..<currentSegmentIndex { start += sequence.segments[i].duration }
        return (sequence.segments[currentSegmentIndex], start)
    }

    /// The play, stamped with where it starts on the Sequence clock and how
    /// long its occurrence runs — the Kit's `Occurrence.start` / `end`.
    private func stamped(_ action: VideoAction) -> VideoAction {
        guard let (segment, start) = firingSegment else { return action }
        var stamped = action
        stamped.firedAt = start + currentFiringOffset
        stamped.timelineSpan = Self.occurrenceSpan(
            channel: action.channel, firedAt: currentFiringOffset, in: segment)
        return stamped
    }

    /// THE SPAN RULE, mirrored from the Kit's Timeline projection: an
    /// occurrence that fires at `offset` into `segment` runs until the same
    /// channel's next stop or play LATER in the Segment (a same-instant action
    /// precedes it by authored order, so it does not end it), else until
    /// the Segment's end.
    public static func occurrenceSpan(channel: String, firedAt offset: TimeInterval,
                                      in segment: SegmentDefinition) -> TimeInterval {
        var end = segment.duration
        let timed: [(TimeInterval, SegmentAction)] =
            segment.actions.map { (0, $0) } + segment.scheduledActions.map { ($0.at, $0.action) }
        for (at, action) in timed where at > offset + 1e-6 && at < end {
            switch action {
            case .stopVideo(let c) where c == channel: end = at
            case .playVideo(let v) where v.channel == channel: end = at
            default: break
            }
        }
        return max(0, end - offset)
    }

    /// Whether a renderable dissolve play on `channel` fires at the SAME
    /// instant as the stop being dispatched — the butted predecessor the
    /// Kit's overlap arbiter requires.
    ///
    /// ANY play, not only a dissolve. A hard cut is a stop and a play at one
    /// instant too, and the plain stop blanks the Screen while the incoming
    /// Clip's player comes up: every cut between two Clips on one Screen
    /// blinked. The outgoing picture is held for both; what the incoming play
    /// does with it (mix it, or simply replace it once it has a frame) is the
    /// video manager's decision.
    private func dissolveFollowsStop(on channel: String) -> Bool {
        guard let (segment, _) = firingSegment else { return false }
        let offset = currentFiringOffset
        let timed: [(TimeInterval, SegmentAction)] =
            segment.actions.map { (0, $0) } + segment.scheduledActions.map { ($0.at, $0.action) }
        return timed.contains { at, action in
            guard abs(at - offset) < 1e-6, case .playVideo(let v) = action,
                  v.channel == channel else { return false }
            return true
        }
    }

    /// The next Clip on `channel` after the one firing now, anywhere later in
    /// the Sequence. The video manager warms it while this one plays.
    static func upcomingVideo(on channel: String, after absoluteTime: TimeInterval,
                              in sequence: SequenceDefinition) -> VideoAction? {
        var segmentStart: TimeInterval = 0
        var best: (time: TimeInterval, action: VideoAction)?
        for segment in sequence.segments {
            let timed: [(TimeInterval, SegmentAction)] =
                segment.actions.map { (0, $0) } + segment.scheduledActions.map { ($0.at, $0.action) }
            for (at, action) in timed {
                guard case .playVideo(let video) = action, video.channel == channel else { continue }
                let time = segmentStart + min(at, segment.duration)
                guard time > absoluteTime + 1e-6 else { continue }
                if best == nil || time < best!.time { best = (time, video) }
            }
            segmentStart += segment.duration
        }
        return best?.action
    }

    /// Async action dispatch — for actions where the executor is actually async.
    private func executeAction(_ action: SegmentAction) async {
        switch action {
        // No async actions in the default SharedVisions action set; extend here as needed.
        default:
            executeActionSync(action)
        }
    }

    /// Synchronous action dispatch — no suspension points.
    private func executeActionSync(_ action: SegmentAction) {
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
        case .setSubElement(let command):
            subElementActionExecutor?.executeSubElementAction(command)
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
            audioExecutor?.play(audioAction, segmentContext: "\(currentSequenceId)/\(currentSegmentId)")
        case .stopAudio(let channel):
            audioExecutor?.stop(channel: channel)
        case .fadeAudio(let channel, let to, let duration):
            audioExecutor?.fade(channel: channel, to: to, duration: duration)

        // Video
        case .playVideo(let videoAction):
            videoExecutor?.play(stamped(videoAction))
            alignToSeek(videoAction)
            // The Clip after this one on the same Screen starts coming up now.
            if let sequence = currentSequence {
                if let next = Self.upcomingVideo(on: videoAction.channel,
                                                 after: sequenceAnimationTime, in: sequence) {
                    videoExecutor?.warm(next)
                } else if let following = followingSequenceProvider?(),
                          let first = Self.upcomingVideo(on: videoAction.channel, after: -1, in: following) {
                    // The last Clip on this Screen in this Sequence: the first
                    // one the NEXT Sequence cuts onto it comes up instead, so
                    // an auto-advance does not open on an empty Screen.
                    videoExecutor?.warm(first)
                }
            }
        case .prepareVideo(let videoAction):
            videoExecutor?.prepare(videoAction)
        case .stopVideo(let channel):
            // A stop that a same-instant dissolve play follows on the same
            // channel HOLDS the outgoing panel for the mix (FL-12); the
            // executor's default is the plain stop.
            videoExecutor?.stop(channel: channel,
                                holdingForDissolve: dissolveFollowsStop(on: channel))

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
            // or discarded (Restart / End). Tearing down from inside a segment
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
        guard let sequence = currentSequence, let segment = currentSegment else { return }

        let status = SequenceStatus(
            sequenceId: sequence.id,
            segmentId: segment.id,
            segmentIndex: currentSegmentIndex,
            segmentName: segment.name,
            segmentElapsed: segmentElapsed,
            segmentDuration: segment.duration,
            totalElapsed: totalElapsed,
            totalDuration: totalDuration,
            totalSegments: sequence.segments.count,
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
