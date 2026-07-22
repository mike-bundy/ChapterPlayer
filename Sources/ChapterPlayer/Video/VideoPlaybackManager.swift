//
//  VideoPlaybackManager.swift
//  SharedVisions
//
//  Channel-based video playback manager.
//  Uses AVPlayer for video content, can display on RealityKit VideoPlayerComponent
//  or inside SwiftUI attachments.
//

import AVFoundation
import RealityKit
import OSLog
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "VideoPlaybackManager"
)

@MainActor
@Observable
public class VideoPlaybackManager {

    public init() {}

    // MARK: - Channel

    private struct VideoChannel {
        /// True once `play(action:)` has been asked for this channel. An
        /// in-flight `prepareAsync` MUST NOT stop/pause/mute a channel the
        /// segment is actually playing — without this flag a preheat that
        /// overlaps a cold play froze the first video's frame (warm-up
        /// `pause()` landing on the live player) or killed it outright
        /// (preheat's entry `stop`).
        var isPlayRequested: Bool = false
        let player: AVPlayer
        var looper: AVPlayerLooper?
        let presentation: VideoPresentation
        var entity: Entity?
        var isPrepared: Bool = false
    }

    // MARK: - State

    private var channels: [String: VideoChannel] = [:]

    /// Video entity registry — entities with VideoPlayerComponent, set up by ImmersiveView
    public var videoEntityRegistry: [String: Entity] = [:]

    /// Channels that survive `stopAll()` — they're managed at a higher
    /// scope than the segment (e.g. `AppModel.backdropVideoChannel`)
    /// and must not be torn down when `SegmentEngine.stop()` resets
    /// per-segment video state at segment transitions. Mirrors the
    /// equivalent `protectedChannels` set on `AudioActionExecutor`.
    public var protectedChannels: Set<String> = []

    // MARK: - Play

    public func play(action: VideoAction) {
        logger.info("[video] play file='\(action.file)' channel='\(action.channel)' presentation=\(String(describing: action.presentation)) layout=\(String(describing: action.layout)) volume=\(action.volume) loop=\(action.loop)")
        // Fast path: channel already created by prepareAsync. If the
        // ModelComponent + VideoMaterial were bound during preheat we
        // SKIP attachToPresentation so RealityKit doesn't tear down +
        // re-upload the texture binding right at the moment the user
        // expects instant playback. We just enable the entity (was
        // disabled to keep the panel hidden during preheat) and call
        // player.play() — first frame appears the same render tick.
        if var ch = channels[action.channel] {
            ch.isPlayRequested = true
            ch.player.volume = action.volume
            if ch.isPrepared, let entity = ch.entity {
                // Already attached during preheat — flip opacity to 1
                // (the OpacityComponent was set to 0 during preheat to
                // keep the entity in the render graph but invisible) and
                // start playback. First frame is already in the GPU
                // texture from the warmup cycle, so it appears the same
                // render tick.
                entity.isEnabled = true
                entity.components.set(OpacityComponent(opacity: 1))
                channels[action.channel] = ch
                ch.player.play()
                logger.info("Playing prepared video on channel '\(action.channel)' (warmed)")
                return
            }
            // Preheat hasn't completed yet (or this play() is running cold
            // over a half-built channel). Do the full attach now, then gate
            // the actual start on item readiness so the panel never shows
            // black while audio runs ahead.
            attachToPresentation(
                player: ch.player,
                presentation: action.presentation,
                channel: &ch
            )
            channels[action.channel] = ch
            startGatedPlayback(player: ch.player, action: action, awaitSourceIn: false)
            return
        }

        stop(channel: action.channel)

        guard let url = findVideoURL(file: action.file) else {
            logger.error("[video] file not found: '\(action.file)' — resolver returned nil and bundle fallback failed")
            return
        }
        logger.info("[video] resolved URL: \(url.absoluteString)")

        // For immersive backdrops we kick off an asynchronous metadata
        // load on the asset. `AVPlayerItem(url:)` doesn't synchronously
        // load tracks, which means AIVU / MV-HEVC files can sit at
        // `item.status = .unknown` for seconds while the player
        // happily reports `.readyToPlay` — RealityKit's
        // VideoPlayerComponent inspects the item, sees no video asset,
        // and refuses to render. Eagerly loading `.isPlayable` and
        // `.tracks` forces the asset to resolve so the player item's
        // status can transition to `.readyToPlay` quickly.
        let asset = AVURLAsset(url: url)
        if case .immersive = action.presentation {
            Task.detached {
                _ = try? await asset.load(.isPlayable, .tracks, .duration)
            }
        }
        let playerItem = AVPlayerItem(asset: asset)

        // Immersive presentations skip `AVPlayerLooper` even when
        // `loop=true`. The looper builds a queue-player that enqueues
        // its first item ASYNCHRONOUSLY — so the player's `currentItem`
        // is nil at the moment we call `attachToPresentation`, and
        // RealityKit's VideoPlayerComponent then skips with
        // "skipping newly added VPC b/c it has no video asset".
        // For immersive video we use a plain AVPlayer (currentItem is
        // set at construction) and loop manually via the
        // `AVPlayerItemDidPlayToEndTime` notification.
        let useLooper: Bool = {
            if !action.loop { return false }
            if case .immersive = action.presentation { return false }
            // Looping a source-trimmed clip needs both endpoints for the
            // looper's timeRange; an in-only trim falls through to the
            // manual observer, which can seek back to sourceIn.
            if (action.sourceIn ?? 0) > 0 && action.sourceOut == nil { return false }
            return true
        }()

        if useLooper {
            let queuePlayer = AVQueuePlayer()
            // Non-destructive trim: loop only the [sourceIn, sourceOut)
            // window of the master.
            let looper: AVPlayerLooper
            if let out = action.sourceOut {
                let start = CMTime(seconds: max(0, action.sourceIn ?? 0), preferredTimescale: 600)
                let end = CMTime(seconds: out, preferredTimescale: 600)
                looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem,
                                        timeRange: CMTimeRange(start: start, end: end))
            } else {
                looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
            }
            queuePlayer.volume = action.volume
            // Don't make the player wait for a full buffer before showing
            // the first frame — visionOS HTTP streaming over the live
            // channel was sometimes stalling for the entire segment step
            // before producing any frame, so the author saw nothing
            // during the step then a paused frame after it ended.
            queuePlayer.automaticallyWaitsToMinimizeStalling = false

            var channel = VideoChannel(
                isPlayRequested: true,
                player: queuePlayer,
                looper: looper,
                presentation: action.presentation
            )
            attachToPresentation(player: queuePlayer, presentation: action.presentation, channel: &channel)
            channels[action.channel] = channel
            // The looper already restricts playback to the source window,
            // so no cue seek is needed — just gate the start on readiness.
            startGatedPlayback(player: queuePlayer, action: action, awaitSourceIn: false)
        } else {
            let player = AVPlayer(playerItem: playerItem)
            player.volume = action.volume
            player.automaticallyWaitsToMinimizeStalling = false
            // Non-destructive source window: cap playback at sourceOut
            // (fires DidPlayToEndTime there). The cue to sourceIn happens
            // inside the gated start below, AWAITED, so a trimmed clip can
            // never flash frame 0 before the seek lands.
            if let out = action.sourceOut {
                playerItem.forwardPlaybackEndTime = CMTime(seconds: out, preferredTimescale: 600)
            }
            // Manual loop for immersive backdrops and in-only trims.
            // Observer loops back to the window start, not frame 0.
            if action.loop {
                let loopStart = CMTime(seconds: max(0, action.sourceIn ?? 0), preferredTimescale: 600)
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak player] _ in
                    player?.seek(to: loopStart, toleranceBefore: .zero, toleranceAfter: .zero)
                    player?.play()
                }
            }

            var channel = VideoChannel(
                isPlayRequested: true,
                player: player,
                presentation: action.presentation
            )
            attachToPresentation(player: player, presentation: action.presentation, channel: &channel)
            channels[action.channel] = channel
            startGatedPlayback(player: player, action: action, awaitSourceIn: true)
        }

        logger.info("Playing video: \(action.file) on channel '\(action.channel)'")
    }

    /// Cold-start gate: the fix for "first video is a black panel with
    /// audible audio." A cold `play()` used to call `player.play()` the
    /// moment the action fired — audio starts within milliseconds, but the
    /// first decoded frame (decoder init + texture upload on a never-warmed
    /// channel) can trail it by hundreds of ms, and `VideoMaterial` renders
    /// black until it arrives. The immersive path always gated its attach on
    /// item readiness; this brings the same discipline to flat panels:
    ///
    ///   1. Flat panels are held at opacity 0 (synchronously, before any
    ///      render tick can show the freshly-bound black material).
    ///   2. Wait for the AVPlayerItem to reach `.readyToPlay`.
    ///   3. For trimmed clips, complete the cue seek to `sourceIn` — awaited,
    ///      so the window start can't flash frame 0.
    ///   4. Preroll, then start playback and reveal one render tick later —
    ///      audio and picture begin together.
    ///
    /// On timeout/failure we start anyway (degraded but audible beats
    /// silent), matching the immersive path's behavior.
    private func startGatedPlayback(player: AVPlayer, action: VideoAction, awaitSourceIn: Bool) {
        if case .entity = action.presentation, let entity = channels[action.channel]?.entity {
            entity.components.set(OpacityComponent(opacity: 0))
        }
        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let isReady = await self.awaitCurrentItemReadyToPlay(player: player, timeout: 8.0)
            if !isReady {
                logger.warning("[video] gated start: item never reached .readyToPlay on channel '\(action.channel)' — starting anyway")
            }
            let sourceIn = max(0, action.sourceIn ?? 0)
            if isReady, awaitSourceIn, sourceIn > 0 {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    player.seek(
                        to: CMTime(seconds: sourceIn, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero
                    ) { _ in cont.resume() }
                }
            }
            if isReady {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    player.preroll(atRate: 1.0) { _ in cont.resume() }
                }
            }
            // The channel may have been stopped/replaced while we waited.
            guard self.channels[action.channel]?.player === player else { return }
            player.play()
            if case .entity = action.presentation, let entity = self.channels[action.channel]?.entity {
                // One render tick (~2 frames at 90 Hz) for the texture
                // upload before revealing; inaudible, invisible.
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard self.channels[action.channel]?.player === player else { return }
                entity.components.set(OpacityComponent(opacity: 1))
            }
        }
    }

    // MARK: - Prepare

    /// Synchronous-ish preheat. Returns when the channel is fully ready
    /// for instant play():
    ///   • AVURLAsset.tracks loaded
    ///   • AVPlayerItem.preroll(atRate: 1.0) complete
    ///   • If `.entity` presentation: ModelComponent (mesh + VideoMaterial)
    ///     bound onto the target entity, so RealityKit's GPU upload
    ///     happens *now* rather than at segment step time
    ///   • A brief play→pause→seek-to-zero cycle so AVPlayer has actually
    ///     produced its first decoded frame and visionOS's video pipeline
    ///     is warm
    ///
    /// Calling `play()` later picks up this prepared channel via the
    /// `isPrepared` fast path and only has to flip `entity.isEnabled` +
    /// `player.play()` — first frame appears in the same render tick.
    /// Apply a VideoAction's non-destructive source window to a live
    /// player/item pair: cap the item at `sourceOut` (so play-to-end fires
    /// there) and cue the player at `sourceIn`. Metadata only — the master
    /// file is untouched. No-op when the action carries no trim.
    private func applySourceWindow(action: VideoAction, playerItem: AVPlayerItem, player: AVPlayer) {
        if let out = action.sourceOut {
            playerItem.forwardPlaybackEndTime = CMTime(seconds: out, preferredTimescale: 600)
        }
        let sourceIn = max(0, action.sourceIn ?? 0)
        if sourceIn > 0 {
            player.seek(
                to: CMTime(seconds: sourceIn, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
        }
    }

    public func prepareAsync(action: VideoAction) async {
        // Never preheat over a channel the segment is already playing —
        // the entry `stop` would kill the live video (the "first video is
        // a black box" race when preheat overlaps a cold play).
        if channels[action.channel]?.isPlayRequested == true { return }
        stop(channel: action.channel)

        guard let url = findVideoURL(file: action.file) else {
            logger.warning("Video file not found for prepare: \(action.file)")
            return
        }

        let asset = AVURLAsset(url: url)

        // Wait for the playable check — calling preroll on an unloaded
        // item throws an ObjC exception (SIGABRT in
        // AVPlayer.prerollAtRate:completionHandler:).
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                logger.warning("Video asset not playable: \(action.file)")
                return
            }
        } catch {
            logger.warning("Video asset load failed for preroll: \(action.file) — \(error.localizedDescription)")
            return
        }

        // Re-check AFTER the await: a real play() may have landed while
        // the asset loaded (it saw no channel and went cold). Storing the
        // preheat channel now would clobber the LIVE player with a muted,
        // paused one — the exact-same-moment "first video is a black box"
        // race. The play path owns the channel; stand down.
        if channels[action.channel]?.isPlayRequested == true { return }

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.volume = 0  // muted during warmup; restored by play()
        player.automaticallyWaitsToMinimizeStalling = false
        // Apply the non-destructive source window BEFORE warmup so the
        // decoder primes at sourceIn and the warmed first frame is the
        // trimmed clip's first frame, not the master's.
        applySourceWindow(action: action, playerItem: playerItem, player: player)

        var channel = VideoChannel(
            player: player,
            presentation: action.presentation,
            isPrepared: false
        )
        channels[action.channel] = channel

        // Bind VideoMaterial onto the target entity NOW so RealityKit
        // uploads the texture binding before segment time.
        attachToPresentation(player: player, presentation: action.presentation, channel: &channel)
        channels[action.channel] = channel

        // Keep the entity ENABLED during preheat — disabling it removes
        // the entity from RealityKit's render graph, which means
        // VideoMaterial's GPU upload doesn't happen until isEnabled flips
        // back at segment time. That re-introduces the multi-second
        // first-frame delay we're trying to eliminate.
        //
        // Instead, drive visibility via OpacityComponent. The entity
        // stays in the render graph (so the texture upload + the brief
        // play→pause cycle below can warm the pipeline) but renders
        // fully transparent until play() flips opacity to 1.
        if let entity = channel.entity {
            entity.isEnabled = true
            entity.components.set(OpacityComponent(opacity: 0))
        }

        // 1) Wait for AVPlayer to reach .readyToPlay before calling
        //    preroll. AVFoundation throws "AVPlayer cannot service a
        //    preroll request until its status is AVPlayerStatusReadyToPlay"
        //    if you ask too early — `asset.load(.isPlayable)` confirms the
        //    asset is decodable but doesn't guarantee the player has
        //    promoted its status yet.
        let isReady = await awaitReadyToPlay(player: player, timeout: 5.0)
        guard isReady else {
            logger.warning("Player never reached .readyToPlay for channel '\(action.channel)' — skipping preroll")
            return
        }

        // 2) Preroll the player so AVPlayer has buffered enough to start
        //    at rate 1.0 without stalling.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.preroll(atRate: 1.0) { _ in cont.resume() }
        }

        // 2) Force visionOS to actually decode + render the first frame.
        //    The trick: play() then pause(), and rely on AVPlayer's
        //    natural position (a few ms in) so the segment step's
        //    eventual play() resumes from a warm decode buffer.
        //
        //    Earlier revisions did `seek(to: .zero, toleranceBefore: .zero,
        //    toleranceAfter: .zero)` here to rewind to exactly frame 0.
        //    Zero-tolerance seek is precise but flushes AVPlayer's
        //    decoded-frame buffer — which destroyed the entire reason
        //    for the warmup. Step 1 of every segment would then play
        //    1+ seconds late while the decoder re-primed. We accept a
        //    handful of frames of offset (the user can't perceive ~50ms
        //    on a segment-step entry) in exchange for actual instant
        //    playback.
        player.play()
        // Two render frames @ ~90Hz on visionOS ≈ 22ms; a touch over
        // gives us margin while staying invisible to the user.
        try? await Task.sleep(nanoseconds: 60_000_000)

        // Stale-task guard before touching the player again.
        guard channels[action.channel]?.player === player else { return }
        if channels[action.channel]?.isPlayRequested == true {
            // A real play() arrived during warm-up — leave the player
            // running (pausing here froze the first video's frame).
            channels[action.channel]?.isPrepared = true
            return
        }
        player.pause()
        channels[action.channel]?.isPrepared = true
        logger.info("Preroll + first-frame warmup complete for channel '\(action.channel)'")
    }

    /// Fire-and-forget version retained for callers that don't need to
    /// await readiness. Wraps the async path in a Task.
    public func prepare(action: VideoAction) {
        Task { @MainActor in
            await self.prepareAsync(action: action)
        }
    }

    /// Wait for AVPlayer.status to transition from `.unknown` to
    /// `.readyToPlay`, returning true on success. Returns false if the
    /// player ends up `.failed` or the timeout elapses. Implemented as a
    /// short polling loop because `Observation` on AVPlayer is finicky
    /// and KVO requires a retained observer object that's awkward to
    /// thread through async/await.
    private func awaitReadyToPlay(player: AVPlayer, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch player.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            case .unknown:
                fallthrough
            @unknown default:
                // ~one frame at 60Hz before re-checking. Keeps the
                // worst-case "wake up just after .readyToPlay flipped"
                // delay below 17ms while staying gentle on CPU.
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        return false
    }

    /// Wait for the player's `currentItem` to reach `.readyToPlay`. This
    /// is stricter than `awaitReadyToPlay(player:)` — `AVPlayer.status`
    /// flips to `.readyToPlay` before the underlying `AVPlayerItem`
    /// finishes loading its decoder/tracks. RealityKit's
    /// `VideoPlayerComponent` checks the *item's* status when deciding
    /// whether it has a "video asset" to render, so an attach that
    /// races ahead of the item's status produces:
    ///   `[RE/ECS] skipping newly added VPC ... b/c it has no video asset`
    /// even when `player.status == .readyToPlay`.
    private func awaitCurrentItemReadyToPlay(player: AVPlayer, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = player.currentItem {
                switch item.status {
                case .readyToPlay:
                    return true
                case .failed:
                    return false
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return false
    }

    // MARK: - Stop

    public func stop(channel: String) {
        guard var ch = channels.removeValue(forKey: channel) else { return }
        ch.player.pause()
        ch.looper = nil

        // Hide / unbind the channel's target entity. For flat panels
        // we just disable it. For the immersive skybox, drop the
        // VideoPlayerComponent so the now-stopped AVPlayer's frame
        // doesn't keep rendering, and disable the entity so the next
        // segment's `applyAmbientBackgroundVisibility` decides
        // whether to bring it back up. No ModelComponent to restore
        // — the video path uses an empty entity + VideoPlayerComponent
        // only.
        switch ch.presentation {
        case .entity(let name, _, _):
            videoEntityRegistry[name]?.isEnabled = false
        case .immersive(_, _):
            if let entity = videoEntityRegistry["skybox"] {
                entity.components.remove(VideoPlayerComponent.self)
                entity.isEnabled = false
            }
        case .attachment:
            break
        }

        logger.debug("Stopped video channel: \(channel)")
    }

    public func pauseAll() {
        for (_, channel) in channels {
            channel.player.pause()
        }
        logger.info("Paused all video (\(self.channels.count) channels)")
    }

    public func resumeAll() {
        for (_, channel) in channels {
            channel.player.play()
        }
        logger.info("Resumed all video (\(self.channels.count) channels)")
    }

    public func stopAll() {
        // `SegmentEngine.stop()` calls this on every segment transition to
        // reset segment-scope video state. Protected channels —
        // currently just `AppModel.backdropVideoChannel` for the
        // segment-level immersive video backdrop — are SCOPED ABOVE
        // segment boundaries and must survive the reset. Without this
        // guard, an immersive video backdrop bound by
        // `applySegmentBackdrop` was getting wiped out the moment the
        // engine started the segment's step loop (because the engine
        // calls stop() before running steps).
        for key in channels.keys where !protectedChannels.contains(key) {
            stop(channel: key)
        }
    }

    // MARK: - Seek

    public func seek(channel: String, to time: TimeInterval) {
        guard let ch = channels[channel] else { return }
        ch.player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    // MARK: - Presentation Attachment

    private func attachToPresentation(player: AVPlayer, presentation: VideoPresentation, channel: inout VideoChannel) {
        switch presentation {
        case .attachment:
            // SwiftUI attachment handles video display — just need the player reference
            break

        case .entity(let name, let width, let height):
            if let entity = videoEntityRegistry[name] {
                logger.info("[video.entity] binding to '\(name)' (parent=\(entity.parent?.name ?? "nil") wasEnabled=\(entity.isEnabled) pos=\(entity.position) opacity=\(entity.components.has(OpacityComponent.self) ? "\(entity.components[OpacityComponent.self]?.opacity ?? -1)" : "no-comp"))")
                entity.isEnabled = true
                #if canImport(RealityKit)
                // Build a ModelComponent on demand using the presentation's
                // authored width/height + VideoMaterial(avPlayer:). This is
                // the same path Maestro Studio's mac viewport uses, where
                // playback is rock-solid. Previously the code added a
                // VideoPlayerComponent on top of an UnlitMaterial
                // placeholder, which on visionOS left the gray placeholder
                // visible and never reliably swapped in the video texture
                // before the segment step ended.
                let mesh = MeshResource.generatePlane(width: width, height: height)
                let material = VideoMaterial(avPlayer: player)
                entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
                // Default to fully visible — preheat callers will dial
                // OpacityComponent down to 0 after this returns; play()
                // callers expect the panel to be visible immediately.
                if entity.components.has(OpacityComponent.self) {
                    entity.components[OpacityComponent.self]?.opacity = 1
                }
                logger.info("[video.entity] '\(name)' bound: isEnabled=\(entity.isEnabled) pos=\(entity.position) scale=\(entity.scale) opacity=\(entity.components.has(OpacityComponent.self) ? "\(entity.components[OpacityComponent.self]?.opacity ?? -1)" : "no-comp")")
                #endif
                channel.entity = entity
            } else {
                logger.warning("Video entity '\(name)' not found in registry. Known: \(self.videoEntityRegistry.keys.sorted())")
            }

        case .immersive(_, _):
            // Immersive 360°/180° video binds to the empty skybox
            // entity created by `ImmersiveView.createSkyboxShell`.
            // Following Apple's `PlayingImmersiveMediaWithRealityKit`
            // sample, we configure `VideoPlayerComponent` with the
            // right viewing-mode hints and let RealityKit handle the
            // spherical projection internally — NO sphere mesh and
            // NO `VideoMaterial` are involved. That's the only way
            // stereo MV-HEVC (AIVU / Apple spatial) renders both
            // eyes correctly.
            //
            // The attach is deferred onto a Task because
            // `VideoPlayerComponent` is rejected by RE/ECS ("no video
            // asset") if its AVPlayerItem hasn't reached
            // `.readyToPlay` at the moment the component is added.
            // The play() path constructs the player and immediately
            // attaches synchronously — too early. We wait for the
            // item to become decodable, then set the component.
            if let entity = videoEntityRegistry["skybox"] {
                logger.info("[video.immersive] binding to 'skybox' entity (parent=\(entity.parent?.name ?? "nil"))")
                entity.isEnabled = true
                channel.entity = entity
                #if canImport(RealityKit)
                Task { @MainActor [weak self, weak entity, weak player] in
                    guard let self, let entity, let player else { return }
                    // Wait on the *item*, not the player. AVPlayer.status
                    // flips early; AVPlayerItem.status is what RE/ECS
                    // checks when deciding "VPC has a video asset."
                    let isReady = await self.awaitCurrentItemReadyToPlay(player: player, timeout: 8.0)
                    guard isReady else {
                        logger.warning("[video.immersive] AVPlayerItem never reached .readyToPlay — skipping VPC attach (item.status=\(player.currentItem?.status.rawValue ?? -1) error=\(player.currentItem?.error?.localizedDescription ?? "none") player.status=\(player.status.rawValue))")
                        return
                    }
                    var component = VideoPlayerComponent(avPlayer: player)
                    component.desiredImmersiveViewingMode = .full
                    component.desiredViewingMode = .stereo
                    entity.components.set(component)
                    logger.info("[video.immersive] VideoPlayerComponent set after item.readyToPlay; player.status=\(player.status.rawValue) currentItem.status=\(player.currentItem?.status.rawValue ?? -1) duration=\(player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan)")
                }
                #endif
            } else {
                logger.error("[video.immersive] 'skybox' entity NOT registered — ImmersiveView.createSkyboxShell never ran or its registration call was lost. videoEntityRegistry keys: \(self.videoEntityRegistry.keys.sorted())")
            }
        }
    }

    // MARK: - Helpers

    /// Optional injected resolver. Consulted ahead of the bundle search so a
    /// downloaded asset pack or a `.chapterscript` folder loaded from disk can
    /// shadow built-in assets without requiring a rebuild.
    public var mediaResolver: MediaResolver?

    private func findVideoURL(file: String) -> URL? {
        // Consult the injected resolver first.
        if let resolved = mediaResolver?.url(for: file, kind: .video) {
            return resolved
        }

        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension

        // Try Media.bundle first
        if let bundlePath = Bundle.main.path(forResource: "Media", ofType: "bundle"),
           let mediaBundle = Bundle(path: bundlePath) {
            if let url = mediaBundle.url(forResource: name, withExtension: ext) {
                return url
            }
            if let url = mediaBundle.url(forResource: name, withExtension: ext, subdirectory: "video") {
                return url
            }
        }

        // Try main bundle
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    /// Get the AVPlayer for a channel (used by SwiftUI attachment views)
    public func player(for channel: String) -> AVPlayer? {
        channels[channel]?.player
    }
}
