//
//  CaptionCueDriver.swift
//  ChapterPlayer
//
//  PLAYING THE CAPTION TRACKS (FL-08). The runtime half of the caption
//  evaluator: which cues are showing NOW, per Track, on the AUTHORED clock
//  (`sequenceAnimationTime`) — so a viewer held at a gate keeps reading the
//  caption that belongs to the moment they are held in, exactly as a fade
//  or a backdrop holds.
//
//  Modelled on `BackdropCueDriver`, and deliberately NOT part of
//  `SequenceEngine`: a caption is not a step, a gate or an action. Polling,
//  not scheduling, for the same five reasons (pause, gate, seek, scrub,
//  next-sequence staleness). The lookup is a binary search over a sorted,
//  non-overlapping list — an hour of captions is thousands of cues and this
//  driver must not know that.
//
//  MIRRORED CONTRACT NOTE: the active-cue rule (half-open [start, end),
//  later cue wins at a touch) and the bundled default style mirror
//  MaestroKit's `CaptionEvaluator` / `CaptionAuthoring.defaultStyle` —
//  ChapterPlayer cannot depend on MaestroKit. Change one, change both.
//

import Foundation
import ChapterScript
import os.log

/// One showing caption, resolved for presentation.
public struct RuntimeCaption: Equatable, Sendable {
    public let trackId: String
    public let language: String
    public let cue: CaptionCue
    public let style: CaptionStyle
}

/// What the driver needs from whatever puts words in space. A protocol so
/// the driver can be exercised without a RealityKit scene.
@MainActor
public protocol CaptionPresenting: AnyObject {
    /// Show exactly these captions (empty = none). Called only when the
    /// showing set CHANGES — remounting identical text is the flickering
    /// mistake this guards against.
    func presentCaptions(_ captions: [RuntimeCaption])
}

@MainActor
public final class CaptionCueDriver {

    private let logger = Logger(subsystem: "ChapterPlayer", category: "CaptionCue")

    /// MIRRORS `MaestroKit.CaptionAuthoring.defaultStyle` — change one,
    /// change both.
    public static let defaultStyle = CaptionStyle(
        id: "captionstyle_default",
        name: "Captions",
        fontSize: 0.045,
        color: ColorRGBA(r: 1, g: 1, b: 1, a: 1),
        backgroundColor: ColorRGBA(r: 0, g: 0, b: 0, a: 0.55),
        maxLineCount: 2,
        maxWidth: 1.6,
        safeAreaInset: 0.08,
        mode: .viewerFacing,
        distance: 1.8)

    private weak var presenter: CaptionPresenting?

    private struct BoundTrack {
        let track: CaptionTrack
        let sortedCues: [CaptionCue]
        let style: CaptionStyle
    }

    private var tracks: [BoundTrack] = []
    private var clock: (() -> TimeInterval)?
    private var ticker: Task<Void, Never>?
    /// The showing set, compared by cue id per track.
    private var activeKey: [String] = []

    /// Captions cut on human speech boundaries; 10 Hz is finer than a cue
    /// swap can be perceived to need.
    private static let tickInterval: Duration = .milliseconds(100)

    public init(presenter: CaptionPresenting) {
        self.presenter = presenter
    }

    // MARK: - Lifecycle

    /// Bind a Sequence's caption Tracks and start following the clock.
    public func begin(tracks captionTracks: [CaptionTrack]?,
                      styles: [CaptionStyle]?,
                      clock: @escaping () -> TimeInterval) {
        stop(tearDown: false)
        self.tracks = (captionTracks ?? []).map { track in
            let style = track.styleId
                .flatMap { id in styles?.first(where: { $0.id == id }) }
                ?? Self.defaultStyle
            return BoundTrack(
                track: track,
                sortedCues: track.cues.sorted {
                    $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id
                },
                style: style)
        }
        self.clock = clock
        self.activeKey = []
        guard !tracks.isEmpty else { return }
        logger.info("[captioncue] following \(self.tracks.count) track(s)")
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    public func stop(tearDown: Bool) {
        ticker?.cancel()
        ticker = nil
        clock = nil
        tracks = []
        if tearDown, !activeKey.isEmpty {
            activeKey = []
            presenter?.presentCaptions([])
        }
    }

    // MARK: - The re-resolve

    func tick() {
        guard let clock else { return }
        let time = clock()
        var showing: [RuntimeCaption] = []
        for bound in tracks {
            guard let index = Self.activeIndex(in: bound.sortedCues, at: time)
            else { continue }
            showing.append(RuntimeCaption(
                trackId: bound.track.id,
                language: bound.track.language,
                cue: bound.sortedCues[index],
                style: bound.style))
        }
        let key = showing.map { "\($0.trackId)|\($0.cue.id)" }
        guard key != activeKey else { return }
        activeKey = key
        presenter?.presentCaptions(showing)
    }

    /// MIRRORS `MaestroKit.CaptionEvaluator.activeIndex` — binary search,
    /// half-open [start, end): at a touch, the LATER cue is showing.
    static func activeIndex(in cues: [CaptionCue], at t: Double) -> Int? {
        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= t {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = candidate, t < cues[index].end else { return nil }
        return index
    }
}

// MARK: - The presenter

#if canImport(RealityKit)
import RealityKit
import UIKit

extension ChapterPlayerCore: CaptionPresenting {

    /// Words in space, through the MIRRORED caption recipe (`CaptionBlock`,
    /// the mirror of MaestroKit's `CaptionGeometry`): FL-07's shaping at
    /// zero depth, per-run bold / italic / colour / underline, the line
    /// limit, the outline halo, on an unlit legibility plate — a caption
    /// nobody can read in a dark shot is a defect. Placement is in the
    /// scene root's own axes, which ARE the viewer's axes (the root is
    /// rebased to the head at Sequence start) — the same viewer-space
    /// convention the Mac editor draws, so a Chapter plays as it was
    /// authored:
    ///
    /// · viewerFacing / composited — ahead of the viewer at the authored
    ///   distance, a little below the line of sight. Continuous
    ///   head-following would contradict the player's no-live-head-yaw
    ///   rule; the rebased root IS the deliberate approximation. There is
    ///   no output frame on a headset, so a composited cue is placed as a
    ///   viewer-facing one.
    /// · screenAttached — a child of the named Screen when it resolves,
    ///   just below it; the viewer-space placement otherwise.
    public func presentCaptions(_ captions: [RuntimeCaption]) {
        captionRootEntity?.removeFromParent()
        captionRootEntity = nil
        guard let sceneRoot = immersiveSceneRoot, !captions.isEmpty else { return }

        let root = Entity()
        root.name = "captions.root"
        var stackY: Float = 0
        for caption in captions {
            guard !caption.cue.text.isEmpty,
                  let built = try? CaptionBlock.build(text: caption.cue.text,
                                                      style: caption.style,
                                                      runs: caption.cue.runs)
            else { continue }
            let block = CaptionBlock.makeBlock(built)
            if caption.style.mode == .screenAttached,
               let screenId = caption.style.screenEntityId,
               let screen = entityExecutor.entityRegistry[screenId] {
                block.position = SIMD3<Float>(0, -0.45, 0.05) + SIMD3<Float>(0, stackY, 0)
                screen.addChild(block)
            } else {
                block.position = CaptionBlock.viewerFacingPosition(style: caption.style)
                    + SIMD3<Float>(0, stackY, 0)
                root.addChild(block)
            }
            stackY += CaptionBlock.stackAdvance(built)
        }
        sceneRoot.addChild(root)
        captionRootEntity = root
    }
}
#endif
