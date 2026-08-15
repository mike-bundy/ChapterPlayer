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

    init(player: AVPlayer, item: AVPlayerItem, file: String,
         sourceRange: MediaSourceRange, requestedVolume: Float, isLooping: Bool) {
        self.player = player
        self.item = item
        self.file = file
        self.sourceRange = sourceRange
        self.requestedVolume = requestedVolume
        self.isLooping = isLooping
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
        let player = AVPlayer(playerItem: item)
        player.volume = effectiveVolume
        // Nothing else may re-spatialise a mix that is already spatial.
        player.automaticallyWaitsToMinimizeStalling = false

        applyPresentation(presentation, to: player, channel: action.channel)

        let channel = SystemSpatialMediaChannel(
            player: player, item: item, file: action.file,
            sourceRange: action.sourceRange,
            requestedVolume: action.volume, isLooping: action.loop)

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

        channels[action.channel] = channel
        player.play()
        logger.info("""
            Playing spatial media: \(action.file, privacy: .public) on \
            '\(action.channel, privacy: .public)' \
            (\(presentation.rawValue, privacy: .public))
            """)
    }

    /// Apply the authored listening frame.
    ///
    /// A LISTENING FRAME, NOT A LOCATION. `.headTracked` leaves the system's
    /// own spatial rendering in charge, which is what an encoded master is for;
    /// `.fixed` asks for the mix to travel with the listener.
    ///
    /// Where the running OS exposes no control for this, the system default
    /// stands and the author is told once — rather than Maestro pretending it
    /// applied something. That is the same declared-degradation rule the router
    /// uses; silence would make an unhonoured setting look like a broken one.
    private func applyPresentation(
        _ presentation: AudioSpatialPresentation, to player: AVPlayer, channel: String
    ) {
        #if os(visionOS)
        // The per-player spatial experience is the supported hook on visionOS.
        // Guarded by availability so an older deployment target still builds
        // and simply keeps the system default.
        if #available(visionOS 2.0, *) {
            switch presentation {
            case .headTracked:
                // The system's default for an encoded spatial master, and the
                // reason to use this pipeline at all.
                break
            case .fixed:
                reportPresentationLimit(
                    channel: channel,
                    note: "Fixed presentation is not applied on this OS; the mix stays head-tracked.")
            }
            return
        }
        #endif
        if presentation == .fixed {
            reportPresentationLimit(
                channel: channel,
                note: "Fixed presentation needs a newer visionOS; the mix stays head-tracked.")
        }
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
