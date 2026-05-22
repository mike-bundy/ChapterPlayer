//
//  ChapterEngine.swift
//  SharedVisions
//
//  Generic step choreographer.
//  Reads ChapterDefinitions and executes StepActions through pluggable executors.
//  Handles timing, pause/resume/skip/goto/restart.
//

import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "ChapterEngine"
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

public struct ChapterStatus: Sendable {
    public let chapterId: String
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
public final class ChapterEngine {


    public init() {}
    // MARK: - State

    public private(set) var currentChapter: ChapterDefinition?
    public private(set) var currentStepIndex: Int = 0
    public private(set) var isPaused: Bool = false
    public private(set) var isPlaying: Bool = false

    // MARK: - Gate State

    public private(set) var isWaiting: Bool = false
    public private(set) var currentGate: StepGate?
    public private(set) var waitStartTime: Date?

    // MARK: - Timing

    private var stepStartTime: Date = .now
    private var chapterStartTime: Date = .now
    private var stepPausedDuration: TimeInterval = 0
    private var chapterPausedDuration: TimeInterval = 0
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
    /// Called when chapter completes
    public var onChapterComplete: ((CompletionAction) -> Void)?
    /// Called to send step status (observers / utility window)
    public var onStatusUpdate: ((ChapterStatus) -> Void)?
    /// Called when a chapter starts playing
    public var onChapterStarted: ((String) -> Void)?
    /// Called when a gate activates — lets ImmersiveView show a prompt
    public var onGateStarted: ((StepGate) -> Void)?
    /// Called when a gate is satisfied — lets ImmersiveView hide the prompt
    public var onGateEnded: (() -> Void)?

    // MARK: - Computed

    public var currentStep: StepDefinition? {
        guard let chapter = currentChapter,
              currentStepIndex >= 0,
              currentStepIndex < chapter.steps.count else { return nil }
        return chapter.steps[currentStepIndex]
    }

    public var currentChapterId: String {
        currentChapter?.id ?? ""
    }

    public var currentStepId: String {
        currentStep?.id ?? ""
    }

    public var totalDuration: TimeInterval {
        currentChapter?.totalDuration ?? 0
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
        let raw = now.timeIntervalSince(chapterStartTime)
        let activePause = pauseStartTime.map { now.timeIntervalSince($0) } ?? 0
        return raw - chapterPausedDuration - activePause
    }

    // MARK: - Play

    /// Starts chapter playback. Use `startingAtStepIndex` to skip earlier steps.
    /// Always resets entities, attachments, and effects to their canonical defaults so
    /// switching chapters starts from a clean slate (SharedVisions policy: safe full reset).
    public func play(chapter: ChapterDefinition, startingAtStepIndex startIndex: Int = 0) {
        stop(resetEntities: true)

        currentChapter = chapter
        let stepCount = chapter.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        chapterPausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += chapter.steps[i].duration
        }
        chapterStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing chapter: \(chapter.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", chapter.totalDuration))s total)")

        startStatusReporting()
        onChapterStarted?(chapter.id)

        logger.notice("▶ play() creating playTask for chapter=\(chapter.id) stepIndex=\(clampedStart)")
        startPlayTask(chapter: chapter, startIndex: clampedStart)
    }

    /// Async variant: runs the step loop in the caller's Task context instead of
    /// creating a new fire-and-forget Task. Use from auto-advance chains.
    /// Always resets entities/attachments/effects (SharedVisions policy).
    public func playAndAwait(chapter: ChapterDefinition, startingAtStepIndex startIndex: Int = 0) async -> CompletionAction? {
        stop(resetEntities: true)

        currentChapter = chapter
        let stepCount = chapter.steps.count
        let clampedStart = max(0, min(startIndex, stepCount > 0 ? stepCount - 1 : 0))
        currentStepIndex = clampedStart
        isPaused = false
        isPlaying = true
        stepPausedDuration = 0
        chapterPausedDuration = 0
        pauseStartTime = nil

        var elapsed: TimeInterval = 0
        for i in 0..<clampedStart {
            elapsed += chapter.steps[i].duration
        }
        chapterStartTime = Date.now.addingTimeInterval(-elapsed)

        logger.info("Playing chapter (await): \(chapter.id) from step index \(clampedStart)/\(stepCount) (\(String(format: "%.1f", chapter.totalDuration))s total)")

        startStatusReporting()
        onChapterStarted?(chapter.id)

        return await runStepsFrom(index: clampedStart, in: chapter)
    }

    // MARK: - Stop

    public func stop(resetEntities: Bool = true, fullReset: Bool = false) {
        if playTask != nil {
            logger.notice("⏹ stop() cancelling playTask for chapter=\(self.currentChapterId) resetEntities=\(resetEntities) fullReset=\(fullReset)")
        }
        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        stopStatusReporting()
        isPaused = false
        isPlaying = false
        stepPausedDuration = 0
        chapterPausedDuration = 0
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
            chapterPausedDuration += elapsed
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
        guard let chapter = currentChapter else { return }
        let nextIndex = currentStepIndex + 1
        guard nextIndex < chapter.steps.count else {
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
        guard let chapter = currentChapter,
              let index = chapter.steps.firstIndex(where: { $0.id == stepId }) else {
            logger.warning("Unknown step ID: \(stepId)")
            return
        }
        jumpToStep(index: index)
    }

    public func jumpToStep(index: Int) {
        guard let chapter = currentChapter,
              index >= 0, index < chapter.steps.count else { return }

        logger.info("Jumping to step index \(index): \(chapter.steps[index].id)")

        playTask?.cancel()
        playTask = nil
        cancelScheduledActions()
        resumeIfPaused()
        clearGate()
        isPaused = false
        stepPausedDuration = 0
        chapterPausedDuration = 0
        pauseStartTime = nil

        audioExecutor?.stopAll()
        videoExecutor?.stopAll()
        cleanup(resetEntities: true)

        var elapsed: TimeInterval = 0
        for i in 0..<index {
            elapsed += chapter.steps[i].duration
        }
        chapterStartTime = Date.now.addingTimeInterval(-elapsed)

        isPlaying = true
        startStatusReporting()

        startPlayTask(chapter: chapter, startIndex: index)
    }

    public func restart() {
        guard let chapter = currentChapter else { return }
        play(chapter: chapter)
    }

    // MARK: - Step Loop

    /// Shared step-iteration loop used by play(), jumpToStep(), and playAndAwait().
    /// Returns the chapter completion only when playback reaches its natural end.
    private func runStepsFrom(index startIndex: Int, in chapter: ChapterDefinition) async -> CompletionAction? {
        let stepCount = chapter.steps.count
        logger.notice("▶ runStepsFrom: chapter=\(chapter.id) startIndex=\(startIndex) stepCount=\(stepCount) isCancelled=\(Task.isCancelled)")

        for index in startIndex..<stepCount {
            let step = chapter.steps[index]
            guard !Task.isCancelled else {
                logger.warning("⚠️ Chapter \(chapter.id) cancelled at step \(step.id) — playTask was cancelled before step could start")
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

        logger.info("Chapter \(chapter.id) complete")

        if case .holdOnLastStep = chapter.onComplete {
            sendStatus(isComplete: true)
        } else {
            isPlaying = false
            stopStatusReporting()
            sendStatus(playing: false)
        }

        return chapter.onComplete
    }

    private func startPlayTask(chapter: ChapterDefinition, startIndex: Int) {
        playTask = Task { @MainActor in
            guard let completion = await self.runStepsFrom(index: startIndex, in: chapter) else { return }
            self.onChapterComplete?(completion)
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
            audioExecutor?.play(audioAction, stepContext: "\(currentChapterId)/\(currentStepId)")
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
        guard let chapter = currentChapter, let step = currentStep else { return }

        let status = ChapterStatus(
            chapterId: chapter.id,
            stepId: step.id,
            stepIndex: currentStepIndex,
            stepName: step.name,
            stepElapsed: stepElapsed,
            stepDuration: step.duration,
            totalElapsed: totalElapsed,
            totalDuration: totalDuration,
            totalSteps: chapter.steps.count,
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
