//
//  SegmentEngine.swift
//  SharedVisions
//
//  Generic step choreographer.
//  Reads SegmentDefinitions and executes StepActions through pluggable executors.
//  Handles timing, pause/resume/skip/goto/restart.
//

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "SegmentEngine"
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

public struct SegmentStatus: Sendable {
    public let segmentId: String
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
public final class SegmentEngine {


    public init() {}
    // MARK: - State

    public private(set) var currentSegment: SegmentDefinition?
    public private(set) var currentStepIndex: Int = 0
    public private(set) var isPaused: Bool = false
    public private(set) var isPlaying: Bool = false

    // MARK: - Gate State

    public private(set) var isWaiting: Bool = false
    public private(set) var currentGate: StepGate?
    public private(set) var waitStartTime: Date?

    // MARK: - Timing

    private var stepStartTime: Date = .now
    private var segmentStartTime: Date = .now
    private var stepPausedDuration: TimeInterval = 0
    private var segmentPausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    // MARK: - Internal

    private var playTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var scheduledActionTasks: [Task<Void, Never>] = []
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateTimeoutTask: Task<Void, Never>?

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
    /// Called when segment completes
    public var onSegmentComplete: ((CompletionAction) -> Void)?
    /// Called to send step status (observers / utility window)
    public var onStatusUpdate: ((SegmentStatus) -> Void)?
    /// Called when a segment starts playing
    public var onSegmentStarted: ((String) -> Void)?
    /// Called when a gate activates — lets ImmersiveView show a prompt
    public var onGateStarted: ((StepGate) -> Void)?
    /// Called when a gate is satisfied — lets ImmersiveView hide the prompt
    public var onGateEnded: (() -> Void)?

    /// Runtime spatial-gate detection (gaze / proximity / grab). Wired by
    /// `ChapterPlayerCore`; runs alongside `onGateStarted`/`onGateEnded`,
    /// which stay reserved for the consumer's prompt UI.
    public weak var gateDetector: GateDetecting?

    // MARK: - Computed

    public var currentStep: StepDefinition? {
        guard let segment = currentSegment,
              currentStepIndex >= 0,
              currentStepIndex < segment.steps.count else { return nil }
        return segment.steps[currentStepIndex]
    }

    public var currentSegmentId: String {
        currentSegment?.id ?? ""
    }

    public var currentStepId: String {
        currentStep?.id ?? ""
    }

    public var totalDuration: TimeInterval {
        currentSegment?.totalDuration ?? 0
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
        let raw = now.timeIntervalSince(segmentStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - segmentPausedDuration - activePause
    }

    // MARK: - Play

    /// Starts segment playback. Use `startingAtStepIndex` to skip earlier steps.
    /// Always resets entities, attachments, and effects to their canonical defaults so
    /// switching segments starts from a clean slate (SharedVisions policy: safe full reset).
    public func play(segment: SegmentDefinition, startingAtStepIndex startIndex: Int = 0) {
        stop(resetEntities: true)

        currentSegment = segment
        let stepCount = segment.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        segmentPausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += segment.steps[i].duration
        }
        segmentStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing segment: \(segment.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", segment.totalDuration))s total)")

        registerSegmentAnimation(segment)
        startStatusReporting()
        onSegmentStarted?(segment.id)

        logger.notice("▶ play() creating playTask for segment=\(segment.id) stepIndex=\(clampedStart)")
        startPlayTask(segment: segment, startIndex: clampedStart)
    }

    /// Async variant: runs the step loop in the caller's Task context instead of
    /// creating a new fire-and-forget Task. Use from auto-advance chains.
    /// Always resets entities/attachments/effects (SharedVisions policy).
    public func playAndAwait(segment: SegmentDefinition, startingAtStepIndex startIndex: Int = 0) async -> CompletionAction? {
        stop(resetEntities: true)

        currentSegment = segment
        let stepCount = segment.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        segmentPausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += segment.steps[i].duration
        }
        segmentStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing segment (await): \(segment.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", segment.totalDuration))s total)")

        registerSegmentAnimation(segment)
        startStatusReporting()
        onSegmentStarted?(segment.id)

        return await runStepsFrom(index: clampedStart, in: segment)
    }

    /// Hand the segment's animation tracks to the entity executor, clocked
    /// by the authored segment time so gates/pauses hold curves in place.
    private func registerSegmentAnimation(_ segment: SegmentDefinition) {
        entityExecutor?.setSegmentAnimation(
            tracks: segment.animationTracks,
            clock: { [weak self] in self?.segmentAnimationTime ?? 0 }
        )
    }

    /// The authored segment clock: absolute seconds along the segment's
    /// step grid — the domain animation-track keys live in. Unlike
    /// `totalElapsed` (wall time minus pauses), this clock stops at a
    /// gated step's end and never drifts when gates stretch real time.
    public var segmentAnimationTime: TimeInterval {
        guard let segment = currentSegment, isPlaying else { return 0 }
        let index = max(0, min(currentStepIndex, segment.steps.count - 1))
        var start: TimeInterval = 0
        for i in 0..<index { start += segment.steps[i].duration }
        let stepDuration = segment.steps.indices.contains(index) ? segment.steps[index].duration : 0
        return start + min(max(stepElapsed, 0), stepDuration)
    }

    // MARK: - Stop

    public func stop(resetEntities: Bool = true, fullReset: Bool = false) {
        if playTask != nil {
            logger.notice("⏹ stop() cancelling playTask for segment=\(self.currentSegmentId) resetEntities=\(resetEntities) fullReset=\(fullReset)")
        }
        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        stopStatusReporting()
        isPaused = false
        isPlaying = false
        stepPausedDuration = 0
        segmentPausedDuration = 0
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
        entityExecutor?.setSegmentAnimation(tracks: [], clock: nil)

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
            segmentPausedDuration += elapsed
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
        guard let segment = currentSegment else { return }
        let nextIndex = currentStepIndex + 1
        guard nextIndex < segment.steps.count else {
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
        guard let segment = currentSegment,
              let index = segment.steps.firstIndex(where: { $0.id == stepId }) else {
            logger.warning("Unknown step ID: \(stepId)")
            return
        }
        jumpToStep(index: index)
    }

    public func jumpToStep(index: Int) {
        guard let segment = currentSegment,
              index >= 0, index < segment.steps.count else { return }

        logger.info("Jumping to step index \(index): \(segment.steps[index].id)")

        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        resumeIfPaused()
        clearGate()
        isPaused = false
        stepPausedDuration = 0
        segmentPausedDuration = 0
        pauseStartTime = nil

        audioExecutor?.stopAll()
        videoExecutor?.stopAll()
        cleanup(resetEntities: true)

        var elapsed: TimeInterval = 0
        for i in 0..<index {
            elapsed += segment.steps[i].duration
        }
        segmentStartTime = Date.now.addingTimeInterval(-elapsed)

        isPlaying = true
        // Re-register the segment's animation tracks: a natural completion
        // deregisters them, so a jump after completion (or after stop)
        // must restore per-frame track sampling like play() does.
        registerSegmentAnimation(segment)
        startStatusReporting()

        startPlayTask(segment: segment, startIndex: index)
    }

    public func restart() {
        guard let segment = currentSegment else { return }
        play(segment: segment)
    }

    // MARK: - Step Loop

    /// Shared step-iteration loop used by play(), jumpToStep(), and playAndAwait().
    /// Returns the segment completion only when playback reaches its natural end.
    private func runStepsFrom(index startIndex: Int, in segment: SegmentDefinition) async -> CompletionAction? {
        let stepCount = segment.steps.count
        logger.notice("▶ runStepsFrom: segment=\(segment.id) startIndex=\(startIndex) stepCount=\(stepCount) isCancelled=\(Task.isCancelled)")

        for index in startIndex..<stepCount {
            let step = segment.steps[index]
            guard !Task.isCancelled else {
                logger.warning("⚠️ Segment \(segment.id) cancelled at step \(step.id) — playTask was cancelled before step could start")
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
            var firedScheduledActions = Set<Int>()

            var remaining = max(0, step.duration - Date.now.timeIntervalSince(stepStartTime))
            while remaining > 0 {
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
                for (i, scheduled) in step.scheduledActions.enumerated() {
                    if !firedScheduledActions.contains(i) && elapsedSinceStepStart >= scheduled.at {
                        firedScheduledActions.insert(i)
                        logger.info("Scheduled action fired at +\(String(format: "%.1f", scheduled.at))s in step \(step.id)")
                        if scheduled.action.isAsync {
                            await executeAction(scheduled.action)
                        } else {
                            executeActionSync(scheduled.action)
                        }
                    }
                }

                let sleepTime = min(remaining, 0.25)
                try? await Task.sleep(for: .seconds(sleepTime))
                remaining = max(0, step.duration - Date.now.timeIntervalSince(stepStartTime))
            }

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
        }

        guard !Task.isCancelled else { return nil }

        logger.info("Segment \(segment.id) complete")

        if case .holdOnLastStep = segment.onComplete {
            sendStatus(isComplete: true)
        } else {
            isPlaying = false
            stopStatusReporting()
            sendStatus(playing: false)
            // Deregister the segment's animation tracks: with isPlaying
            // false the animation clock reads 0, so a still-registered
            // track would slam every keyed entity back to its t=0 pose on
            // the next per-frame sample. Entities keep the final sampled
            // transforms; a subsequent play/jump re-registers.
            entityExecutor?.setSegmentAnimation(tracks: [], clock: nil)
        }

        return segment.onComplete
    }

    private func startPlayTask(segment: SegmentDefinition, startIndex: Int) {
        playTask = Task { @MainActor in
            guard let completion = await self.runStepsFrom(index: startIndex, in: segment) else { return }
            self.onSegmentComplete?(completion)
        }
    }

    // MARK: - Gate

    /// Satisfy the active gate, resuming playback.
    public func satisfyGate() {
        guard isWaiting else { return }
        logger.info("Gate satisfied")
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
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

    /// Wait at a gate, respecting pause. Returns when gate is satisfied or task cancelled.
    private func waitAtGate(_ gate: StepGate) async {
        isWaiting = true
        currentGate = gate
        waitStartTime = .now
        logger.info("Gate activated: \(gate.type.rawValue), timeout=\(gate.timeout.map { String($0) } ?? "none")")

        sendStatus()
        onGateStarted?(gate)
        gateDetector?.gateDidStart(gate) { [weak self] in
            self?.satisfyGate()
        }

        if let timeout = gate.timeout {
            gateTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self.satisfyGate()
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
            audioExecutor?.play(audioAction, stepContext: "\(currentSegmentId)/\(currentStepId)")
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
        guard let segment = currentSegment, let step = currentStep else { return }

        let status = SegmentStatus(
            segmentId: segment.id,
            stepId: step.id,
            stepIndex: currentStepIndex,
            stepName: step.name,
            stepElapsed: stepElapsed,
            stepDuration: step.duration,
            totalElapsed: totalElapsed,
            totalDuration: totalDuration,
            totalSteps: segment.steps.count,
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
