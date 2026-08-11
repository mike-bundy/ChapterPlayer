//
//  BackdropCueDriver.swift
//  ChapterPlayer
//
//  PLAYING THE BACKDROP TRACK, NOT JUST ITS FIRST CUE.
//
//  The document has supported a timed backdrop track for a while — an ordered
//  list of cues, each at an absolute sequence second, each carrying any
//  backdrop kind or `nil` for "none from here". The editors draw it. The
//  runtime ignored all of it and applied `sequence.immersiveBackdrop` once at
//  sequence start, so an authored sequence played its first backdrop and then
//  sat there.
//
//  This is the missing driver. It is deliberately small, and deliberately
//  NOT part of `SequenceEngine`: the engine owns steps, gates and actions, and
//  a backdrop is none of those. It hangs off the engine the same way
//  `gateDetector` does.
//
//  IT RUNS ON THE AUTHORED CLOCK.
//
//  `sequenceAnimationTime` — the same clock animation curves and audio
//  automation sample. Wall time would drift past a gate: a viewer who stands
//  at a gaze gate for thirty seconds would watch the backdrop cut to the next
//  cue while the step they are gated on is still waiting. Cue times are
//  authored against the step grid, so they must be read against the step grid.
//
//  POLLING, NOT SCHEDULING.
//
//  Pre-scheduling each cue with a timer would need cancelling and rebuilding
//  on every pause, gate, seek and scrub — five chances to leave a stale timer
//  that fires a backdrop change during the next sequence. Re-resolving "which
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
        _ spec: SequenceBackdrop?,
        sourceRange: MediaSourceRange,
        presentation: SequencePresentation
    )

    /// Set the mounted backdrop's opacity, 0…1. Called at tick rate during a
    /// cue's fade and otherwise left at 1.
    func setBackdropOpacity(_ opacity: Float)
}

@MainActor
public final class BackdropCueDriver {

    private let logger = Logger(subsystem: "ChapterPlayer", category: "BackdropCue")

    private weak var presenter: BackdropCuePresenting?

    private var cues: [BackdropCue] = []
    private var presentation: SequencePresentation = .immersive
    private var clock: (() -> TimeInterval)?
    private var ticker: Task<Void, Never>?

    /// The cue currently on screen. Compared by ID so a re-resolve that lands
    /// on the same cue does nothing — remounting an identical backdrop is the
    /// expensive, visibly-flickering mistake this guards against.
    private var activeCueId: String?

    /// How often "which cue is it now" is re-answered. 10 Hz is far finer than
    /// a backdrop SWAP can be perceived to need and costs nothing.
    private static let tickInterval: Duration = .milliseconds(100)

    /// …but a FADE is a continuous ramp, and 10 Hz of it is visibly stepped.
    /// Used only while the track actually contains a fade.
    private static let fadingTickInterval: Duration = .milliseconds(33)

    private var tickInterval: Duration {
        cues.contains(where: \.isCrossFaded) ? Self.fadingTickInterval : Self.tickInterval
    }

    public init(presenter: BackdropCuePresenting) {
        self.presenter = presenter
    }

    // MARK: - Lifecycle

    /// Bind a sequence's track and start following it.
    ///
    /// `legacy` is folded in here rather than by the caller so a document that
    /// predates the track behaves identically to one with a single cue at 0 —
    /// one resolution path, which is the rule `SequenceBackdropTimeline` exists
    /// to enforce.
    public func begin(
        track: [BackdropCue],
        legacy: SequenceBackdrop?,
        presentation: SequencePresentation,
        clock: @escaping () -> TimeInterval
    ) {
        stop(tearDown: false)

        self.cues = SequenceBackdropTimeline.effectiveCues(
            track: track,
            legacy: legacy.map { ImmersiveBackdropSpec(runtime: $0) }
        )
        self.presentation = presentation
        self.clock = clock
        self.activeCueId = nil
        self.lastPushedOpacity = 1

        guard !cues.isEmpty else {
            logger.info("[backdropcue] no cues — nothing to follow")
            return
        }

        // Apply cue zero synchronously. Waiting a tick would show the previous
        // sequence's backdrop for 100ms at every sequence start.
        applyCue(at: clock())

        // A single cue that CUTS can never change, so following it is pure
        // overhead. A single cue that FADES still has to be driven — it fades
        // in from nothing at sequence start.
        guard cues.count > 1 || cues.contains(where: \.isCrossFaded) else {
            logger.info("[backdropcue] single hard-cut cue — no ticker needed")
            return
        }
        logger.info("[backdropcue] following \(self.cues.count) cues")
        startTicking()
    }

    /// Stop following. `tearDown` also clears the backdrop — what a sequence
    /// stop wants, and what a sequence SWAP does not (the next sequence's
    /// `begin` will apply its own cue zero, and blanking in between produces a
    /// black flash).
    public func stop(tearDown: Bool) {
        ticker?.cancel()
        ticker = nil
        clock = nil
        cues = []
        lastPushedOpacity = 1
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
                try? await Task.sleep(for: self?.tickInterval ?? Self.tickInterval)
                guard !Task.isCancelled else { return }
                guard let self, let clock = self.clock else { return }
                self.applyCue(at: clock())
            }
        }
    }

    private func applyCue(at time: TimeInterval) {
        let (outgoing, incoming, progress) =
            SequenceBackdropTimeline.transition(at: time, track: cues, legacy: nil)

        // A DIP, NOT A SIMULTANEOUS BLEND — and deliberately so.
        //
        // A true A/B cross-fade needs BOTH backdrops mounted at once, which
        // means a second skybox, a second `VideoPlayerComponent` and a blend
        // between them. Re-attaching that component is the single flakiest
        // thing this pipeline does on device (see the replay fast path in
        // `presentBackdrop`), and doubling it to make a transition prettier
        // would risk the thing that actually has to work. So the outgoing cue
        // fades out over the first half, the swap happens at the midpoint while
        // nothing is visible, and the incoming cue fades in over the second
        // half. Only ever one backdrop mounted, so none of the mounting or
        // teardown logic changes at all.
        //
        // The author still authors ONE number — the total length — and never
        // sees the halves.
        let showing = progress < 0.5 ? outgoing : incoming
        let opacity: Float = {
            guard outgoing != nil, progress < 1 else { return 1 }
            return progress < 0.5
                ? Float(1 - progress * 2)   // out
                : Float(progress * 2 - 1)   // in
        }()

        // Before the first cue there is deliberately NO backdrop — an author
        // whose first cue is at 4s means the first four seconds are bare. The
        // nil-id sentinel distinguishes that from "nothing resolved yet".
        let resolvedId = showing?.id ?? "\u{0}none"
        if resolvedId != activeCueId {
            activeCueId = resolvedId
            logger.info("""
                [backdropcue] t=\(String(format: "%.2f", time))s → cue=\(showing?.id ?? "none") \
                spec=\(showing?.spec == nil ? "nil" : "set")
                """)
            presenter?.presentBackdrop(
                showing?.spec.flatMap { SequenceBackdrop($0) },
                sourceRange: showing?.sourceRange ?? .full,
                presentation: presentation
            )
        }

        // Opacity is pushed EVERY tick while a fade runs, and once on the tick
        // that ends it. Pushing it unconditionally would fight anything else
        // that owns the backdrop's opacity between transitions.
        if opacity < 1 || lastPushedOpacity < 1 {
            lastPushedOpacity = opacity
            presenter?.setBackdropOpacity(opacity)
        }
    }

    /// So the driver stops writing opacity once it has restored it to 1.
    private var lastPushedOpacity: Float = 1
}

// MARK: - The player is the presenter

//  `presentBackdrop` already does the whole job — teardown, the replay fast
//  path, video / image / USDZ mounting — so conformance is a declaration
//  rather than an adapter. The protocol exists to keep the driver testable
//  without a scene, not to add a layer.

extension ChapterPlayerCore: BackdropCuePresenting {}
