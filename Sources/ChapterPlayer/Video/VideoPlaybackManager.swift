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
        /// Request fingerprint — what this channel's player was built FOR.
        /// `play(action:)` compares an incoming action against these before
        /// taking any reuse path; a mismatch (different file, different
        /// source window, different loop mode, different presentation)
        /// tears the channel down and rebuilds cold. Without this check the
        /// warm/half-built paths happily resumed the OLD player — wrong
        /// file, or a played-to-end item that renders as a frozen/black
        /// panel.
        let file: String
        let sourceIn: Double?
        let sourceOut: Double?
        let loop: Bool
        /// Manual-loop DidPlayToEndTime observer token (plain-AVPlayer
        /// loops: immersive, in-only trims, and warmed channels). Removed
        /// on `stop` so tokens don't accumulate across channel rebuilds.
        var loopObserver: NSObjectProtocol?
    }

    // MARK: - State

    private var channels: [String: VideoChannel] = [:]

    /// Monotonic teardown counter, bumped by every `stop(channel:)` /
    /// `stopAll()`. `prepareAsync` snapshots it right after its own entry
    /// teardown and abandons the preheat if ANY stop landed while it was
    /// suspended. Without this, a preheat awaiting its asset load across
    /// `SegmentEngine.play()`'s stopAll could re-store a half-built muted
    /// channel in the gap before step 0's `playVideo` executes — and the
    /// engine's supposedly-cold start would silently adopt that zombie
    /// (skipping the cue discipline the cold path guarantees).
    private var stopEpoch: Int = 0

    /// Video entity registry — entities with VideoPlayerComponent, set up by ImmersiveView
    public var videoEntityRegistry: [String: Entity] = [:]

    // MARK: - Immersive shells

    /// Registry key of the immersive shell entity a channel owns.
    ///
    /// MULTIPLE SIMULTANEOUS IMMERSIVE VIDEOS ARE A PRODUCT FEATURE.
    ///
    /// Every immersive channel used to bind to the ONE `videoEntityRegistry
    /// ["skybox"]` entity. `VideoPlayerComponent` is a single component per
    /// entity, so starting a second AIVU did `components.set(...)` over the
    /// first one's — silently replacing it — and stopping either channel
    /// removed the component both were relying on. Nothing declared "one
    /// immersive video at a time"; the shared host entity enforced it.
    ///
    /// Each channel now owns a shell. The first immersive channel claims the
    /// host-built skybox (so the backdrop path and its careful readiness
    /// handling are untouched); every additional concurrent channel gets its
    /// own sibling shell, released when that channel stops.
    public static func immersiveShellKey(for channel: String) -> String {
        "skybox#\(channel)"
    }

    /// The shell this channel binds its `VideoPlayerComponent` to, creating
    /// one if the base skybox is already claimed by a different live channel.
    private func immersiveShell(for channelKey: String) -> Entity? {
        if let existing = videoEntityRegistry[Self.immersiveShellKey(for: channelKey)] {
            return existing
        }
        guard let base = videoEntityRegistry["skybox"] else { return nil }

        let baseIsClaimed = channels.contains { $0.key != channelKey && $0.value.entity === base }
        if !baseIsClaimed {
            videoEntityRegistry[Self.immersiveShellKey(for: channelKey)] = base
            return base
        }

        // A second concurrent immersive video. Same empty-entity +
        // VideoPlayerComponent recipe as the base shell — RealityKit does the
        // spherical projection, so the shell needs no mesh and no material,
        // and the two videos composite as authored rather than one erasing
        // the other.
        let shell = Entity()
        shell.name = "skybox.\(channelKey)"
        shell.transform = base.transform
        if let parent = base.parent {
            parent.addChild(shell)
        } else {
            logger.warning("[video.immersive] base skybox has no parent — shell for '\(channelKey)' is detached and will not render")
        }
        videoEntityRegistry[Self.immersiveShellKey(for: channelKey)] = shell
        logger.info("[video.immersive] minted a dedicated shell for channel '\(channelKey)' (base skybox already owned by another live channel)")
        return shell
    }

    /// Give up this channel's shell. A cloned shell leaves the scene
    /// entirely; the shared base skybox is only disabled and unbound, exactly
    /// as before. Critically, this touches ONE channel's host — stopping A no
    /// longer strips the component B is rendering through.
    private func releaseImmersiveShell(for channelKey: String) {
        let key = Self.immersiveShellKey(for: channelKey)
        guard let shell = videoEntityRegistry.removeValue(forKey: key) else { return }
        shell.components.remove(VideoPlayerComponent.self)
        if shell === videoEntityRegistry["skybox"] {
            shell.isEnabled = false
            if shell.components.has(OpacityComponent.self) {
                shell.components[OpacityComponent.self]?.opacity = 1
            }
        } else {
            shell.removeFromParent()
        }
    }

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
        if var ch = channels[action.channel], channelMatches(ch, action) {
            ch.isPlayRequested = true
            ch.player.volume = action.volume
            // Warmed channels come from `prepareAsync`, which builds a
            // plain AVPlayer — no AVPlayerLooper. A looping action reusing
            // that player MUST get the manual loop observer or it plays the
            // window once and freezes on the last frame forever.
            if action.loop, ch.looper == nil, ch.loopObserver == nil,
               let item = ch.player.currentItem {
                ch.loopObserver = installManualLoop(
                    player: ch.player, item: item, sourceIn: action.sourceIn
                )
            }
            // The preheat's entity binding must still be the LIVE registry
            // entity — an editor re-materialize replaces every scene
            // entity, and enabling/revealing the stale capture here would
            // light up a detached orphan while the real panel stays
            // invisible. A stale binding falls through to the attach path
            // below, which re-binds against the current registry.
            let boundIsLive: Bool = {
                guard let bound = ch.entity else { return false }
                switch action.presentation {
                case .entity(let name, _, _):
                    return bound === videoEntityRegistry[name]
                case .immersive:
                    // The skybox binding is only live if the deferred
                    // VideoPlayerComponent attach actually LANDED. A
                    // channel whose VPC was refused by RE/ECS ("no video
                    // asset") or stripped by a stop must fall through to
                    // the attach path below, which re-runs the hardened
                    // attach with verification + retry.
                    // Against THIS channel's shell, not the global skybox —
                    // with concurrent immersive channels the base skybox
                    // belongs to whichever channel claimed it first.
                    return bound === videoEntityRegistry[Self.immersiveShellKey(for: action.channel)]
                        && bound.components.has(VideoPlayerComponent.self)
                case .attachment:
                    return true
                }
            }()
            if ch.isPrepared, boundIsLive, let entity = ch.entity {
                entity.isEnabled = true
                // The warm fast path only works when the player is still
                // parked at the clip's start (preheat leaves it ~60ms in).
                // If it's anywhere else — an editor scrub seeked it, or a
                // previous non-looping run played it to the end — play()
                // alone resumes mid-file or holds on the final frame. Cue
                // back to sourceIn behind the opacity gate instead, so the
                // flush-seek can't flash a stale frame.
                let sourceIn = max(0, action.sourceIn ?? 0)
                let current = ch.player.currentItem.map { $0.currentTime().seconds } ?? sourceIn
                if !current.isFinite || abs(current - sourceIn) > 0.75 {
                    entity.components.set(OpacityComponent(opacity: 0))
                    channels[action.channel] = ch
                    startGatedPlayback(player: ch.player, action: action,
                                       awaitSourceIn: true, forceCue: true)
                    logger.info("Re-cueing prepared video on channel '\(action.channel)' (was parked at \(current, format: .fixed(precision: 2))s)")
                    return
                }
                // Already attached during preheat — flip opacity to 1
                // (the OpacityComponent was set to 0 during preheat to
                // keep the entity in the render graph but invisible) and
                // start playback. First frame is already in the GPU
                // texture from the warmup cycle, so it appears the same
                // render tick.
                entity.components.set(OpacityComponent(opacity: 1))
                channels[action.channel] = ch
                ch.player.play()
                logger.info("Playing prepared video on channel '\(action.channel)' (warmed)")
                return
            }
            // Preheat hasn't completed yet (or this play() is running cold
            // over a half-built channel). Do the full attach now, then gate
            // the actual start on item readiness so the panel never shows
            // black while audio runs ahead. Same discipline as the warm
            // path: if the player isn't parked at the clip's start (an
            // editor scrub seeked it mid-preheat), cue back to sourceIn
            // behind the gate instead of resuming from a foreign position.
            attachToPresentation(
                player: ch.player,
                presentation: action.presentation,
                channelKey: action.channel,
                channel: &ch
            )
            channels[action.channel] = ch
            let sourceIn = max(0, action.sourceIn ?? 0)
            let current = ch.player.currentItem.map { $0.currentTime().seconds } ?? sourceIn
            let needsCue = !current.isFinite || abs(current - sourceIn) > 0.75
            startGatedPlayback(player: ch.player, action: action,
                               awaitSourceIn: needsCue, forceCue: needsCue)
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
        //
        // This detached kick only FRONT-RUNS the load (AVAsset coalesces
        // concurrent loads). The load the attach actually depends on is
        // AWAITED in `attachImmersiveComponent` before the VPC is set —
        // do not treat this one as the ordering guarantee.
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
                presentation: action.presentation,
                file: action.file,
                sourceIn: action.sourceIn,
                sourceOut: action.sourceOut,
                loop: action.loop
            )
            attachToPresentation(player: queuePlayer, presentation: action.presentation, channelKey: action.channel, channel: &channel)
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
            var channel = VideoChannel(
                isPlayRequested: true,
                player: player,
                presentation: action.presentation,
                file: action.file,
                sourceIn: action.sourceIn,
                sourceOut: action.sourceOut,
                loop: action.loop
            )
            // Manual loop for immersive backdrops and in-only trims.
            // Observer loops back to the window start, not frame 0.
            if action.loop {
                channel.loopObserver = installManualLoop(
                    player: player, item: playerItem, sourceIn: action.sourceIn
                )
            }
            attachToPresentation(player: player, presentation: action.presentation, channelKey: action.channel, channel: &channel)
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
    /// On timeout/failure we still start playback (degraded but audible
    /// beats silent) — but a flat panel is NOT revealed until its item
    /// actually becomes renderable (see the second readiness wait below):
    /// revealing on a dead item was itself a black-box path.
    ///
    /// `forceCue` seeks to `sourceIn` even when it's 0 — used when reusing
    /// a prepared player that is parked somewhere other than the clip's
    /// start (scrub seek, played-to-end item).
    private func startGatedPlayback(
        player: AVPlayer,
        action: VideoAction,
        awaitSourceIn: Bool,
        forceCue: Bool = false
    ) {
        // Immersive presentations do NOT gate. The skybox shows nothing
        // until the deferred VideoPlayerComponent attach lands, so there
        // is no "black panel with audible audio" window to hide — and
        // gating actively BROKE immersive playback: holding the player
        // paused and prerolling it before RealityKit has bound its video
        // target made the VPC attach land on a parked pipeline
        // (FigVideoTargetRemoteXPC err=-15562 → RE/ECS "skipping newly
        // added VPC b/c it has no video asset" → permanently black
        // skybox). The original, working immersive path called play()
        // immediately and let the attach task catch up — restore exactly
        // that: cue if the source window needs it, then start rolling.
        if case .immersive = action.presentation {
            let sourceIn = max(0, action.sourceIn ?? 0)
            if awaitSourceIn, sourceIn > 0 || forceCue {
                player.seek(
                    to: CMTime(seconds: sourceIn, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            }
            player.play()
            logger.info("[video.immersive] playback started ungated on channel '\(action.channel)' (VPC attach follows item readiness)")
            return
        }
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
            if isReady, awaitSourceIn, sourceIn > 0 || forceCue {
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
            if case .entity = action.presentation {
                if !isReady {
                    // The 8s gate elapsed with no decodable item. Revealing
                    // now would show a black panel — keep it hidden and keep
                    // waiting. play() is already called, so the moment the
                    // item recovers AVPlayer starts producing frames; we
                    // reveal then. Only after an extended grace period do we
                    // reveal regardless (with a loud log) so a broken file
                    // can't hide the panel forever once it self-heals.
                    let recovered = await self.awaitCurrentItemReadyToPlay(player: player, timeout: 30.0)
                    if !recovered {
                        logger.error("[video] gated start: revealing channel '\(action.channel)' after 38s without .readyToPlay (file '\(action.file)') — panel may render black")
                    }
                }
                // One render tick (~2 frames at 90 Hz) for the texture
                // upload before revealing; inaudible, invisible.
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard self.channels[action.channel]?.player === player else { return }
                // Reveal the entity the registry names NOW — not the one
                // captured when the gate armed. A long gate can outlive
                // the captured binding (editor re-materialize replaces
                // every scene entity; or the attach found no registry
                // entry because play() raced the registry's population).
                // Revealing the stale capture flips opacity on a detached
                // orphan while the REAL panel stays invisible forever —
                // the "video at t=0 never appears" terminal state.
                if let entity = self.resolveLivePanelEntity(for: action) {
                    entity.isEnabled = true
                    entity.components.set(OpacityComponent(opacity: 1))
                }
            }
        }
    }

    /// The panel entity a gated reveal should target: the CURRENT registry
    /// entity for `.entity` presentations. When the channel's stored
    /// binding is missing (attach ran before the registry was populated)
    /// or stale (a re-materialize swapped the scene's entities under the
    /// gate), re-run the attach against the live registry entity so the
    /// video material lands on the panel that is actually in the scene.
    private func resolveLivePanelEntity(for action: VideoAction) -> Entity? {
        guard var ch = channels[action.channel] else { return nil }
        guard case .entity(let name, _, _) = action.presentation else {
            return ch.entity
        }
        guard let live = videoEntityRegistry[name] else {
            // Nothing registered under this name — the stored binding
            // (possibly nil) is the best we have.
            return ch.entity
        }
        if let bound = ch.entity, bound === live {
            return bound
        }
        logger.warning("[video] gated reveal: channel '\(action.channel)' bound entity was \(ch.entity == nil ? "nil" : "stale") — re-attaching to live registry entity '\(name)'")
        attachToPresentation(player: ch.player, presentation: action.presentation, channelKey: action.channel, channel: &ch)
        channels[action.channel] = ch
        return ch.entity
    }

    // MARK: - Channel reuse validation

    /// True when an existing channel was built for exactly this request —
    /// same file, same non-destructive source window, same loop mode, same
    /// presentation target. Anything else must go through stop + cold
    /// rebuild: the reuse paths never re-create the AVPlayerItem, so a
    /// mismatched reuse plays the WRONG content (or a played-out item that
    /// renders as a frozen/black panel). A failed item is never reusable.
    private func channelMatches(_ ch: VideoChannel, _ action: VideoAction) -> Bool {
        if ch.player.currentItem?.status == .failed { return false }
        guard ch.file == action.file,
              max(0, ch.sourceIn ?? 0) == max(0, action.sourceIn ?? 0),
              ch.sourceOut == action.sourceOut,
              ch.loop == action.loop
        else { return false }
        switch (ch.presentation, action.presentation) {
        case (.attachment(let a), .attachment(let b)):
            return a == b
        case (.entity(let n1, let w1, let h1), .entity(let n2, let w2, let h2)):
            return n1 == n2 && w1 == w2 && h1 == h2
        case (.immersive(let r1, let f1), .immersive(let r2, let f2)):
            return r1 == r2 && f1 == f2
        default:
            return false
        }
    }

    /// Install the manual DidPlayToEndTime loop used everywhere an
    /// AVPlayerLooper can't be (immersive backdrops, in-only trims, and
    /// warmed channels whose player was built by `prepareAsync`). Loops
    /// back to the source-window start, not frame 0. Returns the observer
    /// token; `stop(channel:)` removes it.
    private func installManualLoop(
        player: AVPlayer, item: AVPlayerItem, sourceIn: Double?
    ) -> NSObjectProtocol {
        let loopStart = CMTime(seconds: max(0, sourceIn ?? 0), preferredTimescale: 600)
        return NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: loopStart, toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
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
        // Snapshot AFTER the entry teardown (which bumps the epoch
        // itself). Any stop that lands during the awaits below means the
        // world moved on — a segment start, a jump, a project switch —
        // and this preheat must abandon rather than re-store a channel
        // the engine just tore down.
        let epoch = stopEpoch

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
        // race. The play path owns the channel; stand down. Likewise a
        // stop/stopAll while we awaited: the next play must be genuinely
        // cold, not run over a zombie preheat stored after its teardown.
        if channels[action.channel]?.isPlayRequested == true { return }
        guard stopEpoch == epoch else { return }

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
            isPrepared: false,
            file: action.file,
            sourceIn: action.sourceIn,
            sourceOut: action.sourceOut,
            loop: action.loop
        )
        channels[action.channel] = channel

        // Bind VideoMaterial onto the target entity NOW so RealityKit
        // uploads the texture binding before segment time.
        attachToPresentation(player: player, presentation: action.presentation, channelKey: action.channel, channel: &channel)
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
        // A stop while we waited removed this channel — do NOT run the
        // warmup play() below on the orphaned player (it would keep
        // decoding, muted and unbound, forever).
        guard channels[action.channel]?.player === player else { return }

        // 2) Preroll the player so AVPlayer has buffered enough to start
        //    at rate 1.0 without stalling.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.preroll(atRate: 1.0) { _ in cont.resume() }
        }
        guard channels[action.channel]?.player === player else { return }

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
        // Every teardown invalidates in-flight preheats (see `stopEpoch`)
        // — even when the channel doesn't exist yet: a prepareAsync that
        // hasn't stored its channel is exactly the one that must not
        // re-store it after this stop.
        stopEpoch += 1
        guard var ch = channels.removeValue(forKey: channel) else { return }
        ch.player.pause()
        ch.looper = nil
        if let token = ch.loopObserver {
            NotificationCenter.default.removeObserver(token)
            ch.loopObserver = nil
        }

        // Hide / unbind the channel's target entity. For flat panels
        // we just disable it. For the immersive skybox, drop the
        // VideoPlayerComponent so the now-stopped AVPlayer's frame
        // doesn't keep rendering, and disable the entity so the next
        // segment's `applyAmbientBackgroundVisibility` decides
        // whether to bring it back up. No ModelComponent to restore
        // — the video path uses an empty entity + VideoPlayerComponent
        // only.
        //
        // Either way, clear any preheat/gate-era opacity-0 back to 1:
        // the entity is disabled (invisible) regardless, and a later
        // `showEntity`/reveal or a fresh backdrop bind must not inherit
        // a stale fully-transparent OpacityComponent — that was the
        // "revealed panel/skybox renders nothing" black-box path.
        switch ch.presentation {
        case .entity(let name, _, _):
            if let entity = videoEntityRegistry[name] {
                entity.isEnabled = false
                if entity.components.has(OpacityComponent.self) {
                    entity.components[OpacityComponent.self]?.opacity = 1
                }
            }
        case .immersive(_, _):
            releaseImmersiveShell(for: channel)
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
        // Only resume channels the segment actually asked to play.
        // Preheat-only channels are deliberately parked at the clip's
        // first frame (paused, opacity 0) — blanket-playing them here let
        // a pause/resume cycle silently run a warmed video to its end, so
        // the eventual real play() started mid-file or on a dead frame.
        for (_, channel) in channels where channel.isPlayRequested {
            channel.player.play()
        }
        logger.info("Resumed all requested video channels")
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
        // Bump once even when no channels exist yet: preheats still in
        // their asset-load await (channel not stored) must also observe
        // this teardown and stand down.
        stopEpoch += 1
        for key in channels.keys where !protectedChannels.contains(key) {
            stop(channel: key)
        }
    }

    // MARK: - Seek

    public func seek(channel: String, to time: TimeInterval) {
        guard let ch = channels[channel] else { return }
        ch.player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    /// In-flight scrub seeks per channel, with the latest requested time
    /// parked until the current one lands (coalescing — a scrub drag emits
    /// dozens of seeks a second and issuing each directly thrashes the
    /// decoder into showing stale frames).
    private var scrubSeekInFlight: Set<String> = []
    private var scrubSeekPending: [String: TimeInterval] = [:]

    /// Frame-accurate park for editor scrubbing: zero-tolerance seek with
    /// per-channel coalescing. The latest requested time always lands last.
    public func scrubSeek(channel: String, to time: TimeInterval) {
        guard let ch = channels[channel] else { return }
        if scrubSeekInFlight.contains(channel) {
            scrubSeekPending[channel] = time
            return
        }
        scrubSeekInFlight.insert(channel)
        ch.player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scrubSeekInFlight.remove(channel)
                if let next = self.scrubSeekPending.removeValue(forKey: channel) {
                    self.scrubSeek(channel: channel, to: next)
                }
            }
        }
    }

    // MARK: - Presentation Attachment

    private func attachToPresentation(player: AVPlayer, presentation: VideoPresentation, channelKey: String, channel: inout VideoChannel) {
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
                // Rounded corners ride on the entity (stamped from
                // VideoPanelSpec at materialize) — the geometry clips,
                // the video texture stays rect-mapped.
                let radius = entity.components[VideoPanelStyleComponent.self]?.cornerRadius ?? 0
                let mesh = MeshResource.generatePlane(
                    width: width, height: height,
                    cornerRadius: min(radius, min(width, height) / 2)
                )
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
            // item to become decodable, then set the component —
            // and VERIFY RealityKit actually accepted it (see
            // `attachImmersiveComponent`): a skipped VPC never
            // re-evaluates on its own, so refusal without retry left
            // the skybox permanently black (AIVU regression).
            if let entity = immersiveShell(for: channelKey) {
                logger.info("[video.immersive] channel '\(channelKey)' binding to shell '\(entity.name)' (parent=\(entity.parent?.name ?? "nil"))")
                entity.isEnabled = true
                // A previous preheat may have left the skybox at opacity 0
                // (prepareAsync dials the bound entity down after attach).
                // The immersive gate never touches OpacityComponent, so
                // without this reset a cold backdrop play rendered its
                // video fully transparent — an all-black immersive space.
                // Preheat callers re-apply opacity 0 right after this
                // returns, same as the flat-panel branch.
                if entity.components.has(OpacityComponent.self) {
                    entity.components[OpacityComponent.self]?.opacity = 1
                }
                channel.entity = entity
                #if canImport(RealityKit)
                Task { @MainActor [weak self, weak entity, weak player] in
                    guard let self, let entity, let player else {
                        logger.warning("[video.immersive] deferred attach abandoned before running — manager/entity/player deallocated (channel '\(channelKey)')")
                        return
                    }
                    await self.attachImmersiveComponent(
                        channelKey: channelKey, player: player, entity: entity
                    )
                }
                #endif
            } else {
                logger.error("[video.immersive] 'skybox' entity NOT registered — ImmersiveView.createSkyboxShell never ran or its registration call was lost. videoEntityRegistry keys: \(self.videoEntityRegistry.keys.sorted())")
            }
        }
    }

    /// The hardened immersive VPC attach. Every stage logs, every exit is
    /// loud — the AIVU regression hid behind silent returns.
    ///
    ///   1. AWAIT the asset's `.isPlayable/.tracks/.duration` load (the
    ///      old fire-and-forget `Task.detached` eager load gave RE/ECS no
    ///      ordering guarantee) and verify a video track exists. AIVU /
    ///      MV-HEVC assets sit at `.unknown` for seconds without this.
    ///   2. Wait for the AVPlayerItem (not the player — its status flips
    ///      early) to reach `.readyToPlay`. On timeout we attach anyway:
    ///      visionOS 26's VPC tolerates a not-yet-ready item, and the
    ///      verify+retry below recovers if it doesn't. The old code
    ///      *skipped* the attach on timeout — a guaranteed-black skybox.
    ///   3. Liveness guard by PLAYER IDENTITY, not stop-epoch: the epoch
    ///      bumps on every `stopAll()`, including the segment-transition
    ///      one that PROTECTED channels (the segment backdrop) survive —
    ///      an epoch guard here would kill the backdrop's own in-flight
    ///      attach. Identity survives protected stops and fails for
    ///      genuinely stopped/replaced channels.
    ///   4. Attach and VERIFY. RE/ECS refuses a VPC whose player it can't
    ///      bind a video target to ("skipping newly added VPC … b/c it
    ///      has no video asset", FigVideoTargetRemoteXPC err=-15562) and
    ///      a skipped component never re-evaluates. We poll
    ///      `currentRenderingStatus` and, if it never reaches `.ready`,
    ///      remove + re-add a FRESH component (a skipped instance is
    ///      dead) up to three times.
    private func attachImmersiveComponent(
        channelKey: String, player: AVPlayer, entity: Entity
    ) async {
        // 1) Eager load, awaited.
        if let asset = player.currentItem?.asset as? AVURLAsset {
            do {
                let (isPlayable, tracks, duration) = try await asset.load(.isPlayable, .tracks, .duration)
                let videoTrackCount = tracks.filter { $0.mediaType == .video }.count
                logger.info("[video.immersive] asset loaded: playable=\(isPlayable) tracks=\(tracks.count) videoTracks=\(videoTrackCount) duration=\(CMTimeGetSeconds(duration), format: .fixed(precision: 2))s (channel '\(channelKey)')")
                if videoTrackCount == 0 {
                    logger.error("[video.immersive] asset has NO video track — RealityKit will refuse the VPC (channel '\(channelKey)', url=\(asset.url.lastPathComponent))")
                }
            } catch {
                logger.error("[video.immersive] asset load FAILED for channel '\(channelKey)': \(error.localizedDescription) — attempting attach anyway")
            }
        }

        // 2) Item readiness (attach proceeds either way).
        let isReady = await awaitCurrentItemReadyToPlay(player: player, timeout: 8.0)
        if !isReady {
            logger.warning("[video.immersive] AVPlayerItem not .readyToPlay after 8s (item.status=\(player.currentItem?.status.rawValue ?? -1) error=\(player.currentItem?.error?.localizedDescription ?? "none") player.status=\(player.status.rawValue)) — attaching anyway; verify/retry below recovers if RealityKit refuses")
        }

        // 3) Protection-aware liveness.
        guard channels[channelKey]?.player === player else {
            logger.info("[video.immersive] channel '\(channelKey)' was stopped or rebuilt while waiting — abandoning attach")
            return
        }

        // 4) Attach + verify + retry.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            var component = VideoPlayerComponent(avPlayer: player)
            component.desiredImmersiveViewingMode = .full
            component.desiredViewingMode = .stereo
            entity.components.remove(VideoPlayerComponent.self)
            entity.components.set(component)
            logger.info("[video.immersive] VideoPlayerComponent set (attempt \(attempt)/\(maxAttempts)); player.status=\(player.status.rawValue) currentItem.status=\(player.currentItem?.status.rawValue ?? -1) duration=\(player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan)")

            // RealityKit flips `currentRenderingStatus` to `.ready` once
            // the video target is bound and producing; a refused VPC
            // stays `.loading` forever.
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                if entity.components[VideoPlayerComponent.self]?.currentRenderingStatus == .ready {
                    logger.info("[video.immersive] VPC rendering .ready on attempt \(attempt) (channel '\(channelKey)')")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard channels[channelKey]?.player === player else {
                logger.info("[video.immersive] channel '\(channelKey)' torn down mid-verify — abandoning attach")
                return
            }
            if attempt < maxAttempts {
                logger.warning("[video.immersive] VPC not rendering after 2.5s (attempt \(attempt)/\(maxAttempts)) — RealityKit likely skipped it ('no video asset'); re-attaching a fresh component")
            }
        }
        logger.error("[video.immersive] VPC never reached .ready after \(maxAttempts) attempts — skybox will stay black (channel '\(channelKey)', item.status=\(player.currentItem?.status.rawValue ?? -1) item.error=\(player.currentItem?.error?.localizedDescription ?? "none"))")
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
