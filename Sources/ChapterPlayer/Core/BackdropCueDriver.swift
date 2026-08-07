//
//  BackdropCueDriver.swift
//  ChapterPlayer
//
//  PLAYING THE BACKDROP TRACK, NOT JUST ITS FIRST CUE.
//
//  The document has supported a timed backdrop track for a while — an ordered
//  list of cues, each at an absolute segment second, each carrying any
//  backdrop kind or `nil` for "none from here". The editors draw it. The
//  runtime ignored all of it and applied `segment.immersiveBackdrop` once at
//  segment start, so an authored sequence played its first backdrop and then
//  sat there.
//
//  This is the missing driver. It is deliberately small, and deliberately
//  NOT part of `SegmentEngine`: the engine owns steps, gates and actions, and
//  a backdrop is none of those. It hangs off the engine the same way
//  `gateDetector` does.
//
//  IT RUNS ON THE AUTHORED CLOCK.
//
//  `segmentAnimationTime` — the same clock animation curves and audio
//  automation sample. Wall time would drift past a gate: a viewer who stands
//  at a gaze gate for thirty seconds would watch the backdrop cut to the next
//  cue while the step they are gated on is still waiting. Cue times are
//  authored against the step grid, so they must be read against the step grid.
//
//  POLLING, NOT SCHEDULING.
//
//  Pre-scheduling each cue with a timer would need cancelling and rebuilding
//  on every pause, gate, seek and scrub — five chances to leave a stale timer
//  that fires a backdrop change during the next segment. Re-resolving "which
//  cue governs NOW" from the clock is stateless: pause it, gate it, scrub it
//  backwards, and the answer is still just a function of the time. 10 Hz is
//  far finer than a backdrop swap can be perceived to need and costs nothing.
//

import Foundation
import ChapterScript
import os.log

/// What the driver needs from whatever actually mounts a backdrop. Kept as a
/// protocol so the driver can be exercised without a RealityKit scene.
@MainActor
public protocol BackdropCuePresenting: AnyObject {
    /// Show `spec` (nil = tear down and show nothing), playing `sourceRange`
    /// of it when it is a video.
    func presentBackdrop(
        _ spec: SegmentBackdrop?,
        sourceRange: MediaSourceRange,
        presentation: SegmentPresentation
    )
}

@MainActor
public final class BackdropCueDriver {

    private let logger = Logger(subsystem: "ChapterPlayer", category: "BackdropCue")

    private weak var presenter: BackdropCuePresenting?

    private var cues: [BackdropCue] = []
    private var presentation: SegmentPresentation = .immersive
    private var clock: (() -> TimeInterval)?
    private var ticker: Task<Void, Never>?

    /// The cue currently on screen. Compared by ID so a re-resolve that lands
    /// on the same cue does nothing — remounting an identical backdrop is the
    /// expensive, visibly-flickering mistake this guards against.
    private var activeCueId: String?

    /// How often "which cue is it now" is re-answered.
    private static let tickInterval: Duration = .milliseconds(100)

    public init(presenter: BackdropCuePresenting) {
        self.presenter = presenter
    }

    // MARK: - Lifecycle

    /// Bind a segment's track and start following it.
    ///
    /// `legacy` is folded in here rather than by the caller so a document that
    /// predates the track behaves identically to one with a single cue at 0 —
    /// one resolution path, which is the rule `SegmentBackdropTimeline` exists
    /// to enforce.
    public func begin(
        track: [BackdropCue],
        legacy: SegmentBackdrop?,
        presentation: SegmentPresentation,
        clock: @escaping () -> TimeInterval
    ) {
        stop(tearDown: false)

        self.cues = SegmentBackdropTimeline.effectiveCues(
            track: track,
            legacy: legacy.map { ImmersiveBackdropSpec(runtime: $0) }
        )
        self.presentation = presentation
        self.clock = clock
        self.activeCueId = nil

        guard !cues.isEmpty else {
            logger.info("[backdropcue] no cues — nothing to follow")
            return
        }

        // Apply cue zero synchronously. Waiting a tick would show the previous
        // segment's backdrop for 100ms at every segment start.
        applyCue(at: clock())

        // A single cue can never change, so following it is pure overhead.
        guard cues.count > 1 else {
            logger.info("[backdropcue] single cue — no ticker needed")
            return
        }
        logger.info("[backdropcue] following \(self.cues.count) cues")
        startTicking()
    }

    /// Stop following. `tearDown` also clears the backdrop — what a segment
    /// stop wants, and what a segment SWAP does not (the next segment's
    /// `begin` will apply its own cue zero, and blanking in between produces a
    /// black flash).
    public func stop(tearDown: Bool) {
        ticker?.cancel()
        ticker = nil
        clock = nil
        cues = []
        if tearDown {
            activeCueId = nil
            presenter?.presentBackdrop(nil, sourceRange: .full, presentation: presentation)
        }
    }

    /// Re-resolve immediately — for a scrub or seek, where waiting up to a
    /// tick would show the wrong backdrop under the author's playhead.
    public func syncNow() {
        guard let clock else { return }
        applyCue(at: clock())
    }

    // MARK: - Following

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled else { return }
                guard let self, let clock = self.clock else { return }
                self.applyCue(at: clock())
            }
        }
    }

    private func applyCue(at time: TimeInterval) {
        let cue = SegmentBackdropTimeline.activeCue(at: time, track: cues, legacy: nil)

        // Before the first cue there is deliberately NO backdrop — an author
        // whose first cue is at 4s means the first four seconds are bare. The
        // nil-id sentinel distinguishes that from "nothing resolved yet".
        let resolvedId = cue?.id ?? "\u{0}none"
        guard resolvedId != activeCueId else { return }
        activeCueId = resolvedId

        logger.info("""
            [backdropcue] t=\(String(format: "%.2f", time))s → cue=\(cue?.id ?? "none") \
            spec=\(cue?.spec == nil ? "nil" : "set")
            """)
        presenter?.presentBackdrop(
            cue?.spec.flatMap { SegmentBackdrop($0) },
            sourceRange: cue?.sourceRange ?? .full,
            presentation: presentation
        )
    }
}

// MARK: - The player is the presenter

//  `presentBackdrop` already does the whole job — teardown, the replay fast
//  path, video / image / USDZ mounting — so conformance is a declaration
//  rather than an adapter. The protocol exists to keep the driver testable
//  without a scene, not to add a layer.

extension ChapterPlayerCore: BackdropCuePresenting {}
