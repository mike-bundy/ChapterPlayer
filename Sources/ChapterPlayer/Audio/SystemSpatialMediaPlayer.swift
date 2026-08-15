//
//  SystemSpatialMediaPlayer.swift
//  ChapterPlayer
//
//  PIPELINE B — encoded spatial masters, played by the system, kept intact.
//
//  Maestro has two meanings of "spatial" and they must not collapse into one:
//
//    A. A POSITIONAL SOURCE is an object in the scene. Footsteps, a phone, a
//       helicopter. It has X/Y/Z, an emitter the author can grab and keyframe,
//       and it belongs on the RealityKit path (`SpatialAudioManager.playSpatial`).
//
//    B. AN ENCODED SPATIAL MASTER already contains its own spatial scene. ASAF
//       (APAC) and Dolby Atmos are mixes, not points. Asking where the Atmos
//       master IS is a category error, and giving it a `SpatialAudioComponent`
//       would spatialise an already-spatialised mix — the classic
//       double-spatialization fault.
//
//  This file is B, and its one job is to NOT TOUCH THE AUDIO. The asset goes to
//  `AVPlayer` whole. It is never opened with `AVAudioFile`, never scheduled into
//  `AVAudioEngine`, never given a location. Opening these files as sample
//  buffers is exactly what destroys them — measured on the owner's media:
//
//      ASAF.mp4          -> 18 discrete channels (APAC flattened)
//      Dolby Spatial.mp4 -> a 5.1 bed, JOC objects already gone
//
//  WHAT MAESTRO STILL CONTRIBUTES: the listening frame
//  (`AudioSpatialPresentation` — head-tracked or fixed, a rendering concept,
//  not a transform), narrative gain, and the Sequence clock. Everything else is
//  the system renderer's.
//
//  THE CLOCK IS STILL MAESTRO'S. An encoded player is driven by STATE CHANGES —
//  play, pause, seek at a gate or a jump — never by a per-frame seek. Seeking an
//  `AVPlayer` every display frame is how you get a stutter and a hot CPU; the
//  Sequence tells it when something happened, not what time it is.
//

import Foundation
import AVFoundation
import AudioToolbox
import OSLog
import ChapterScript

/// One encoded-spatial occurrence in flight.
@MainActor
final class SystemSpatialMediaChannel {
    let player: AVPlayer
    let item: AVPlayerItem
    let file: String
    /// Where in the MASTER this occurrence starts, so a resume can be corrected
    /// without consulting the file again.
    let sourceRange: MediaSourceRange
    /// The gain Maestro asked for, before bus/category/master scaling. Kept so
    /// a later master change can be re-applied without losing the clip's own
    /// level.
    var requestedVolume: Float
    var isLooping: Bool
    var loopObserver: NSObjectProtocol?
    /// Held so the load-status observation survives until the item resolves.
    var statusObservation: NSKeyValueObservation?
    /// The authored listening frame, kept so any re-prepare can reapply it
    /// rather than silently reverting to the system default.
    let presentation: AudioSpatialPresentation

    init(player: AVPlayer, item: AVPlayerItem, file: String,
         sourceRange: MediaSourceRange, requestedVolume: Float, isLooping: Bool,
         presentation: AudioSpatialPresentation) {
        self.player = player
        self.item = item
        self.file = file
        self.sourceRange = sourceRange
        self.requestedVolume = requestedVolume
        self.isLooping = isLooping
        self.presentation = presentation
    }
}

@MainActor
final class SystemSpatialMediaPlayer {

    private let logger = Logger(subsystem: "com.maestro.chapterplayer", category: "SpatialMedia")
    private var channels: [String: SystemSpatialMediaChannel] = [:]

    /// Occurrences whose presentation the platform could not honour, reported
    /// once each so a scrubbing author does not get the same line repeatedly.
    private var reportedPresentationLimits: Set<String> = []

    // MARK: - Start

    /// Play `url` as an encoded spatial master on `channel`.
    ///
    /// `effectiveVolume` is passed in rather than computed here: the mix
    /// (bus / category / master / ducking) is `SpatialAudioManager`'s to own,
    /// and duplicating that arithmetic is how two gain answers appear.
    func play(
        action: AudioAction,
        url: URL,
        effectiveVolume: Float,
        presentation: AudioSpatialPresentation
    ) {
        stop(channel: action.channel)

        // THE ASSET, UNTOUCHED. No AVAudioFile, no buffers, no engine.
        let item = AVPlayerItem(url: url)

        // MULTICHANNEL SPATIALIZATION MUST BE ASKED FOR.
        //
        // `allowedAudioSpatializationFormats` defaults to `.monoAndStereo`, so
        // an encoded spatial master — the ONLY kind of asset that reaches this
        // pipeline — is by default the one thing the system will not
        // spatialise. Measured on the owner's files: ASAF.mp4 is `apac` with
        // 18 channels and Dolby Spatial.mp4 is `ec-3` with 6; both load and
        // report `isDecodable`, so the file was never the problem.
        //
        // This is also why the two failed DIFFERENTLY on device and looked
        // like unrelated bugs: 5.1 has a defined stereo downmix, so Dolby
        // stayed audible (unspatialised, but there); 18 discrete APAC channels
        // have no such fallback, so ASAF rendered nothing at all. Silence and
        // a flat mix were the same defect wearing two faces.
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        let player = makePlayer(item: item, presentation: presentation,
                                volume: effectiveVolume, channel: action.channel)

        let channel = SystemSpatialMediaChannel(
            player: player, item: item, file: action.file,
            sourceRange: action.sourceRange,
            requestedVolume: action.volume, isLooping: action.loop,
            presentation: presentation)

        // A marked cue starts at its in-point. ONE seek, at start — not a
        // per-frame correction.
        if let start = action.sourceRange.sourceIn, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if action.loop {
            channel.loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.restart(channel: action.channel) }
            }
        }

        // WHY AN ENCODED MASTER FAILED, IN THE LOG.
        //
        // Device QA found Dolby playing and ASAF silent through this exact
        // path — same folder, same code, one works. Without the item status
        // there is nothing to go on but "no sound", and the difference between
        // "the file did not load" and "it played and was inaudible" is the
        // whole diagnosis. Observed once per occurrence, not polled.
        let file = action.file
        channel.statusObservation = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            let status = observed.status
            let reason = observed.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .failed:
                    self.logger.error("Spatial media FAILED to load \(file, privacy: .public): \(reason ?? "unknown", privacy: .public)")
                case .readyToPlay:
                    self.logger.info("Spatial media ready: \(file, privacy: .public)")
                default:
                    break
                }
            }
        }

        channels[action.channel] = channel
        player.play()
        logger.info("""
            Playing spatial media: \(action.file, privacy: .public) on \
            '\(action.channel, privacy: .public)' \
            (\(presentation.rawValue, privacy: .public))
            """)

        probeAfterStart(channel: action.channel, file: action.file)
    }

    /// DID IT PLAY SILENTLY, OR NOT PLAY AT ALL? — one sample, 1.5s in.
    ///
    /// The two produce the same report from a listener ("no sound") and have
    /// nothing in common as defects: a transport that never moved is a
    /// loading, routing or URL problem, while a transport running normally
    /// with nothing audible is a RENDERING problem. Device QA burned several
    /// rounds on ASAF for want of exactly this distinction, so it is measured
    /// rather than inferred.
    ///
    /// `print` alongside the logger deliberately: OSLog does not reach
    /// `devicectl --console`, and being able to read this over the cable is
    /// the difference between diagnosing it and asking the owner for another
    /// screen recording.
    private func probeAfterStart(channel: String, file: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, let ch = self.channels[channel] else { return }
            let t = CMTimeGetSeconds(ch.player.currentTime())
            let moved = t > 0.2
            let line = """
                [SPATIAL-PROBE] \(file) ch=\(channel) \
                transport=\(moved ? "RUNNING" : "STALLED") t=\(String(format: "%.2f", t))s \
                rate=\(ch.player.rate) vol=\(ch.player.volume) \
                status=\(ch.item.status.rawValue) \
                keepUp=\(ch.item.isPlaybackLikelyToKeepUp) \
                err=\(ch.item.error?.localizedDescription ?? "none") \
                => \(moved ? "playing but INAUDIBLE (rendering)" : "never started (load/route)")
                """
            print(line)
            self.logger.info("\(line, privacy: .public)")
        }
    }

    /// THE ONLY PLACE AN `AVPlayer` IS CONSTRUCTED.
    ///
    /// A choke point on purpose. The listening frame is not a one-time setup
    /// step that a later code path can skip: source replacement, a loop
    /// restart, a re-prepare after a seek — any of them producing a fresh
    /// player would otherwise silently revert to the system default while the
    /// Inspector still showed the author's choice. Route every construction
    /// through here and that cannot happen.
    private func makePlayer(
        item: AVPlayerItem,
        presentation: AudioSpatialPresentation,
        volume: Float,
        channel: String
    ) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.volume = volume
        player.automaticallyWaitsToMinimizeStalling = false
        applyPresentation(presentation, to: player, channel: channel)
        return player
    }

    /// Apply the authored listening frame to the REAL PLAYER.
    ///
    /// THIS USED TO BE DECORATIVE. The first version switched on the
    /// presentation and did nothing with it — `.headTracked` fell through to
    /// `break`, `.fixed` only logged — so the Inspector control configured
    /// metadata and the player kept the system default. The whole point of
    /// pipeline B is that the author decides the listening frame, so it now
    /// sets the actual property.
    ///
    /// `AVPlayer.intendedSpatialAudioExperience` (visionOS 26.0) is the
    /// per-player hook. Per-player, deliberately: a chapter can hold a
    /// RealityKit positional source, an ordinary head-locked cue and an encoded
    /// head-tracked master at the same time, and imposing one presentation on
    /// all of them through the audio session would be wrong for two of the
    /// three. The session is left alone.
    ///
    /// SOUND STAGE SIZE IS LEFT AUTOMATIC in both cases. It is a separate
    /// creative axis (how widely the channels are spread) that Maestro does not
    /// expose, and choosing one here would silently override the mix's own
    /// intent. Anchoring is automatic for the same reason — Maestro does not
    /// author a UIScene anchor, so the system's choice is the honest one.
    private func applyPresentation(
        _ presentation: AudioSpatialPresentation, to player: AVPlayer, channel: String
    ) {
        #if os(visionOS)
        if #available(visionOS 26.0, *) {
            // The mapping itself lives in `AudioRuntimeRouting` so it can be
            // pinned by a test — this package is visionOS-only and has none.
            defer {
                // READ THE PROPERTY BACK AND LOG WHAT IT ACTUALLY HOLDS.
                //
                // This is the evidence a listening test needs when Head Tracked
                // and Fixed sound the same: it separates "Maestro never applied
                // it" from "the renderer does not distinguish them for this
                // asset". Without it that result is a dead end, and the first
                // instinct would be to change code that is already correct.
                let held = String(describing: player.intendedSpatialAudioExperience)
                logger.info("\(channel, privacy: .public): requested \(presentation.rawValue, privacy: .public), player holds \(held, privacy: .public)")
            }
            switch AudioRuntimeRouting.spatialExperience(for: presentation) {
            case .headTracked:
                // The mix stays anchored to the room and follows head motion —
                // what an encoded spatial master is for.
                player.intendedSpatialAudioExperience =
                    .headTracked(.automatic, soundStageSize: .automatic)
            case .fixed:
                // The mix travels with the listener: spatialised, but not
                // motion-tracked. NOT `.bypassed`, which would remove spatial
                // processing altogether and flatten the master — a different
                // and much worse thing than "fixed".
                player.intendedSpatialAudioExperience =
                    .fixed(soundStageSize: .automatic)
            }
            return
        }
        // Older visionOS has no per-player hook. Say so rather than let the
        // Inspector imply a setting that was never applied.
        reportPresentationLimit(
            channel: channel,
            note: """
                \(presentation.displayName) presentation needs visionOS 26; \
                the system default is in force.
                """)
        #else
        // Non-visionOS builds (the Mac editor links this package) have no
        // spatial experience to set. Nothing is claimed and nothing is logged.
        _ = (presentation, player, channel)
        #endif
    }

    private func reportPresentationLimit(channel: String, note: String) {
        guard reportedPresentationLimits.insert(channel).inserted else { return }
        logger.warning("'\(channel, privacy: .public)': \(note, privacy: .public)")
    }

    // MARK: - Sequence clock

    /// STATE CHANGES ONLY — never a per-frame seek.
    func pause(channel: String)  { channels[channel]?.player.pause() }

    func resume(channel: String) { channels[channel]?.player.play() }

    func pauseAll()  { for (_, c) in channels { c.player.pause() } }
    func resumeAll() { for (_, c) in channels { c.player.play() } }

    /// Correct the encoded player to an authored source time — a gate release,
    /// a Timeline jump, an authored seek. Called ONCE per event.
    ///
    /// `elapsed` is Sequence time since this occurrence began; the master time
    /// comes from `MediaSourceRange`, which is the one mapping in the system and
    /// is not re-derived here.
    func seek(channel: String, toElapsed elapsed: Double, masterDuration: Double?) {
        guard let ch = channels[channel] else { return }
        let target = ch.sourceRange.sourceTime(
            forElapsed: elapsed, masterDuration: masterDuration, looping: ch.isLooping)
        ch.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Gain

    /// Narrative mixing still applies: clip volume, fades, master and ducking
    /// all arrive here as one already-composed scalar. `AVPlayer.volume` is a
    /// straight output gain and does not disturb the spatial render.
    func setVolume(_ volume: Float, channel: String) {
        channels[channel]?.player.volume = volume
    }

    var activeChannels: [String] { Array(channels.keys) }

    func isActive(channel: String) -> Bool { channels[channel] != nil }

    func volume(channel: String) -> Float? { channels[channel]?.player.volume }

    func isPlaying(channel: String) -> Bool {
        guard let ch = channels[channel] else { return false }
        return ch.player.timeControlStatus == .playing
    }

    // MARK: - Stop

    private func restart(channel: String) {
        guard let ch = channels[channel] else { return }
        let start = ch.sourceRange.sourceIn ?? 0
        ch.player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
        ch.player.play()
    }

    func stop(channel: String) {
        guard let ch = channels.removeValue(forKey: channel) else { return }
        if let observer = ch.loopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        ch.player.pause()
        ch.player.replaceCurrentItem(with: nil)
        reportedPresentationLimits.remove(channel)
    }

    func stopAll() {
        for channel in channels.keys { stop(channel: channel) }
    }
}
