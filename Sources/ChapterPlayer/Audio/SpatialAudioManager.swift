//
//  SpatialAudioManager.swift
//  SharedVisions
//
//  Channel-based audio playback manager.
//  Supports spatial audio via RealityKit AudioFileResource + Entity.playAudio()
//  and ambient/non-spatial audio via AVAudioEngine.
//

@preconcurrency import AVFoundation
import AudioToolbox
import RealityKit
import OSLog
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "SpatialAudioManager"
)

// MARK: - Audio Mix State (1A)

public struct AudioMixState: Sendable {
    public var masterVolume: Float = 1.0
    public var categoryVolumes: [String: Float] = [
        "ambient": 1.0,
        "scene_audio": 1.0,
        "sfx": 1.0,
        "narration": 1.0,
        "video": 1.0,
    ]
}

// MARK: - Channel State (1B)

public struct ChannelState: Sendable {
    public let channel: String
    public let file: String
    public let isPlaying: Bool
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let progress: Double
}

// MARK: - Preload Report (1C)

public struct AudioPreloadReport: Sendable {
    public let totalFiles: Int
    public let loadedFiles: Int
    public let missingFiles: [String]
    public let failedFiles: [(file: String, error: String)]
    public var isComplete: Bool { missingFiles.isEmpty && failedFiles.isEmpty }

    /// Non-tuple version for display
    public var failedDescriptions: [String] {
        failedFiles.map { "\($0.file): \($0.error)" }
    }
}

// MARK: - Loop Playback State (2C)

private enum LoopPhase {
    case playingIntro
    case looping
    case playingOutro
    case stopped
}

private struct LoopState {
    public var config: LoopConfig
    public var phase: LoopPhase
    public var transitionTask: Task<Void, Never>?
    public var stepContext: String?
}

// MARK: - Zone Tracking State (3A)

private enum ZoneActivity {
    case active(channel: String)
    case fadingOut(channel: String)
}

@MainActor
@Observable
public class SpatialAudioManager {

    /// Channels already reported as playing degraded — see `reportFallback`.
    private var reportedFallbackChannels: Set<String> = []

    /// PIPELINE B. Encoded spatial masters, played by the system with the asset
    /// intact — never opened as buffers, never given a location. See
    /// `SystemSpatialMediaPlayer`.
    private let systemSpatialMedia = SystemSpatialMediaPlayer()
    /// In-flight gain ramps for encoded masters, so a new fade supersedes the
    /// old one rather than fighting it.
    private var systemSpatialFadeTasks: [String: Task<Void, Never>] = [:]
    /// Fallback mapping for catalog audio names that are referenced by scenes
    /// but not shipped in the current Media.bundle.
    private static let audioFileFallbacks: [String: String] = [
        "panel_whoosh.mp3": "ParticleSweepSound_04.mp3",
        "countdown_tick.mp3": "ParticleSweepSound_03.wav",
        "data_confirm.mp3": "ParticleSweepSound_02.wav",
        "shatter_glass.mp3": "ParticleSweepSound_04.mp3",
        "gentle_ambience.mp3": "amb-test.mp3",
        "mechanical_rise.mp3": "ParticleSweepSound_04.mp3",
        "deep_resonance.mp3": "ParticleSweepSound_03.wav",
        "servo_glide.mp3": "ParticleSweepSound_02.wav",
        "ambient_room.mp3": "StarWaves.mp3",
    ]

    // MARK: - Channel Types

    private struct AmbientChannel {
        var playerNode: AVAudioPlayerNode
        var audioFile: AVAudioFile
        var targetVolume: Float          // Requested volume (before mix pipeline)
        var fadeTask: Task<Void, Never>?
        var file: String
        var isLooping: Bool
        var busId: String
        // Crossfade (2A)
        var outgoingPlayerNode: AVAudioPlayerNode?
        var outgoingFadeTask: Task<Void, Never>?
    }

    private struct SpatialChannel {
        let entity: Entity
        var controller: AudioPlaybackController?
        var targetVolume: Float
        var file: String
        var startTime: Date
        var duration: TimeInterval
    }

    // MARK: - AVAudioEngine (3B)

    private let audioEngine = AVAudioEngine()
    private var busMixerNodes: [String: AVAudioMixerNode] = [:]
    private var busEffectChains: [String: [AVAudioNode]] = [:]

    // MARK: - State

    /// Pre-staged ambient channels — see prewarmBeat(). Survives stopAll() (scene transitions);
    /// cleared by stopEverything() (full shutdown). At most 4 unique channel entries in current catalog.
    private var prewarmedChannels: [String: AmbientChannel] = [:]

#if DEBUG
    /// Test seam: pool entry count. Use in unit tests to assert prewarm state without
    /// exposing private internals.
    public var prewarmedChannelCount: Int { prewarmedChannels.count }

    /// Test seam: duck trigger reference count for a channel. Allows tests to verify
    /// ducking is not doubled on a prewarm hit.
    public func duckTriggerCountForTesting(channel: String) -> Int {
        duckTriggerCount[channel, default: 0]
    }
#endif

    private var ambientChannels: [String: AmbientChannel] = [:]
    private var spatialChannels: [String: SpatialChannel] = [:]
    private var preloadedResources: [String: AudioFileResource] = [:]

    // MARK: - Preload Cache

    /// URL cache populated by preload(). Used by findAudioURL() for catalog files.
    /// Populated alongside preloadedResources in preload() — they share the same lifecycle.
    public private(set) var resolvedURLs: [String: URL] = [:]

    // MARK: - Mix State (1A)

    public var mixState = AudioMixState() {
        didSet { applyMixToAllChannels() }
    }

    // MARK: - Channel categories (1A)

    private var channelCategories: [String: String] = [:]

    // MARK: - Buses (3B)

    public private(set) var buses: [String: AudioBus] = [:]
    private var channelBusOverrides: [String: String] = [:]

    // MARK: - Zones (3A)

    private var zones: [String: AudioZone] = [:]
    private var activeZoneChannels: [String: String] = [:]  // zoneId → channel name
    private var listenerPosition: SIMD3<Float> = .zero

    // MARK: - Completion Callbacks (1B)

    public var onChannelFinished: ((String) -> Void)?

    /// Fired when a channel is removed (stopped) — used by AudioActionExecutor
    /// to clean up protectedChannels for scope-based lifecycle (spec 030).
    public var onChannelStopped: ((String) -> Void)?

    // MARK: - Loop State (2C)

    private var loopStates: [String: LoopState] = [:]

    // MARK: - Ducking

    public var duckingRules: [DuckingRule] = []
    private var preDuckVolumes: [String: Float] = [:]
    private var duckedChannels: Set<String> = []
    private var duckTriggerCount: [String: Int] = [:]
    private var duckMultipliers: [String: Float] = [:]

    // MARK: - Sound Variations (2B)

    private var variationRegistry: [String: SoundVariation] = [:]
    private var variationIndices: [String: Int] = [:]
    private var variationShuffleOrders: [String: [Int]] = [:]

    /// Root entity for spatial audio sources.
    public let audioRoot = Entity()

    /// Entity lookup closure — set by ImmersiveView to resolve entity names.
    public var entityLookup: ((String) -> Entity?)? = nil

    /// Number of currently active audio zones.
    public var activeZoneCount: Int { activeZoneChannels.count }

    // MARK: - Performance Instrumentation (Phase 1 — spec 038)

#if DEBUG
    /// Signposter for audio path profiling. Measures cold-start costs at beat 1.
    /// Visible in Instruments → Logging track under subsystem "groovejones.hsbc", category "AudioPerf".
    private let audioSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
        category: "AudioPerf"
    )
    /// Counts audioEngine.attach() calls. Reset to 0 between test cases.
    /// Prewarm hit path must not increment this — tests assert 0 after consuming a prewarmed channel.
    public var attachCallCount: Int = 0
#endif

    // MARK: - Init

    public init() {
        setupDefaultBuses()
    }

    // MARK: - Engine Management (3B)

    private func ensureEngineRunning() {
#if DEBUG
        let _s = audioSignposter.beginInterval("audio_engine_start")
        defer { audioSignposter.endInterval("audio_engine_start", _s) }
#endif
        guard !audioEngine.isRunning else { return }
        do {
            try audioEngine.start()
            logger.info("AVAudioEngine started")
        } catch {
            logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)")
        }
    }

    private func setupDefaultBuses() {
        let defaultBusIds = ["ambient_bus", "music_bus", "scene_audio_bus", "sfx_bus", "narration_bus", "video_bus"]
        for busId in defaultBusIds {
            let mixer = AVAudioMixerNode()
            audioEngine.attach(mixer)
            audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: nil)
            busMixerNodes[busId] = mixer
            buses[busId] = AudioBus(id: busId)
        }
    }

    // MARK: - Bus Routing (3B)

    public func busForChannel(_ channel: String) -> String {
        if let override = channelBusOverrides[channel] { return override }
        if channel.hasPrefix("ambient_music") { return "music_bus" }
        if channel.hasPrefix("ambient") || channel.hasPrefix("zone_") { return "ambient_bus" }
        if channel.hasPrefix("scene_audio") { return "scene_audio_bus" }
        if channel.hasPrefix("sfx") { return "sfx_bus" }
        if channel.hasPrefix("narration") { return "narration_bus" }
        if channel.hasPrefix("video") || channel.hasPrefix("main_video") { return "video_bus" }
        return "sfx_bus"
    }

    private func connectPlayerToBus(_ playerNode: AVAudioPlayerNode, format: AVAudioFormat, busId: String) {
        if let busMixer = busMixerNodes[busId] {
            audioEngine.connect(playerNode, to: busMixer, format: format)
        } else {
            // Create bus on demand
            let mixer = AVAudioMixerNode()
            audioEngine.attach(mixer)
            audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: nil)
            busMixerNodes[busId] = mixer
            buses[busId] = AudioBus(id: busId)
            audioEngine.connect(playerNode, to: mixer, format: format)
        }
    }

    private func cleanupPlayerNode(_ node: AVAudioPlayerNode) {
        node.stop()
        audioEngine.disconnectNodeInput(node)
        audioEngine.disconnectNodeOutput(node)
        audioEngine.detach(node)
    }

    // MARK: - Bus Volume (3B)

    public func setBusVolume(_ busId: String, volume: Float) {
        let clamped = max(0, min(1, volume))
        buses[busId]?.volume = clamped
        applyMixToAllChannels()
        logger.info("Bus '\(busId)' volume → \(clamped)")
    }

    // MARK: - Bus Effects (3B)

    public func setBusEffect(busId: String, effect: AudioEffect) {
        guard var bus = buses[busId] else { return }
        if !bus.effects.contains(effect) {
            bus.effects.append(effect)
            buses[busId] = bus
            rebuildBusEffectChain(busId: busId)
            logger.info("Added effect to bus '\(busId)'")
        }
    }

    public func removeBusEffect(busId: String, effect: AudioEffect) {
        guard var bus = buses[busId] else { return }
        bus.effects.removeAll { $0 == effect }
        buses[busId] = bus
        rebuildBusEffectChain(busId: busId)
        logger.info("Removed effect from bus '\(busId)'")
    }

    private func rebuildBusEffectChain(busId: String) {
        guard let busMixer = busMixerNodes[busId],
              let bus = buses[busId] else { return }

        // Remove existing effect nodes
        if let existingNodes = busEffectChains[busId] {
            for node in existingNodes {
                audioEngine.disconnectNodeInput(node)
                audioEngine.disconnectNodeOutput(node)
                audioEngine.detach(node)
            }
        }

        // Disconnect bus mixer output
        audioEngine.disconnectNodeOutput(busMixer)

        if bus.effects.isEmpty {
            audioEngine.connect(busMixer, to: audioEngine.mainMixerNode, format: nil)
            busEffectChains[busId] = []
        } else {
            var effectNodes: [AVAudioNode] = []
            for effect in bus.effects {
                switch effect {
                case .reverb(let wetDryMix):
                    let reverb = AVAudioUnitReverb()
                    reverb.wetDryMix = wetDryMix * 100  // AVAudioUnitReverb uses 0–100
                    reverb.loadFactoryPreset(.mediumHall)
                    audioEngine.attach(reverb)
                    effectNodes.append(reverb)
                case .compressor(let threshold, let ratio):
                    let componentDesc = AudioComponentDescription(
                        componentType: kAudioUnitType_Effect,
                        componentSubType: kAudioUnitSubType_DynamicsProcessor,
                        componentManufacturer: kAudioUnitManufacturer_Apple,
                        componentFlags: 0,
                        componentFlagsMask: 0
                    )
                    let compressor = AVAudioUnitEffect(audioComponentDescription: componentDesc)
                    audioEngine.attach(compressor)
                    // Configure via AudioUnit parameters
                    let au = compressor.audioUnit
                    AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold,
                                          kAudioUnitScope_Global, 0, threshold, 0)
                    AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom,
                                          kAudioUnitScope_Global, 0, max(0.1, 20.0 / max(1, ratio)), 0)
                    AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime,
                                          kAudioUnitScope_Global, 0, 0.001, 0)
                    AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime,
                                          kAudioUnitScope_Global, 0, 0.05, 0)
                    effectNodes.append(compressor)
                }
            }

            // Chain: busMixer → effect1 → effect2 → … → mainMixer
            var previousNode: AVAudioNode = busMixer
            for node in effectNodes {
                audioEngine.connect(previousNode, to: node, format: nil)
                previousNode = node
            }
            audioEngine.connect(previousNode, to: audioEngine.mainMixerNode, format: nil)

            busEffectChains[busId] = effectNodes
        }
    }

    // MARK: - Prewarm (spec 038)

    /// Pre-stage ambient audio channels for a beat’s actions before the beat engine starts.
    /// Call from playCatalogScene() before beatEngine.play(). The prewarm completes synchronously
    /// before beatEngine.play() starts its async Task, guaranteeing beat 1 finds pre-staged nodes.
    ///
    /// Only covers the simple ambient path (spatial == nil, loopConfig == nil).
    /// loopConfig channels have multi-phase scheduling (intro/loop/outro) and are not prewarmed.
    public func prewarmStep(actions: [StepAction]) {
        for action in actions {
            guard case .playAudio(let audioAction) = action,
                  audioAction.spatial == nil,
                  audioAction.loopConfig == nil else { continue }
            prewarmAmbientChannel(audioAction)
        }
    }

    private func prewarmAmbientChannel(_ action: AudioAction) {
        let resolvedFile = resolveVariation(for: action.file)

        // Clean up any existing prewarm entry for this channel (overwrite, not accumulate).
        if let existing = prewarmedChannels.removeValue(forKey: action.channel) {
            cleanupPlayerNode(existing.playerNode)
        }

        ensureEngineRunning()

        guard let url = findAudioURL(file: resolvedFile) else {
            logger.error("Prewarm skipped — file not found: \(resolvedFile), channel: \(action.channel)")
            return
        }
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let playerNode = AVAudioPlayerNode()
            let busId = busForChannel(action.channel)

            audioEngine.attach(playerNode)
#if DEBUG
            attachCallCount += 1
#endif
            connectPlayerToBus(playerNode, format: audioFile.processingFormat, busId: busId)

            if action.loop {
                // loopConfig == nil guard above ensures this is a simple loop, not intro/loop/outro
                let buffer = try loadBuffer(from: audioFile, sourceRange: action.sourceRange)
                playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            } else {
                scheduleAmbientFile(playerNode, file: audioFile, channel: action.channel,
                                    sourceRange: action.sourceRange)
            }

            prewarmedChannels[action.channel] = AmbientChannel(
                playerNode: playerNode,
                audioFile: audioFile,
                targetVolume: action.volume,
                file: resolvedFile,
                isLooping: action.loop,
                busId: busId
            )
            logger.info("Prewarm ready: \(resolvedFile) on '\(action.channel)'")
        } catch {
            logger.error("Prewarm failed for \(resolvedFile): \(error.localizedDescription)")
        }
    }

    // MARK: - Preload

    public func preload(files: [String]) -> AudioPreloadReport {
        var missingFiles: [String] = []
        var failedFiles: [(file: String, error: String)] = []
        var loadedCount = 0

        // Include variation pool files
        var allFiles = Set(files)
        for (_, variation) in variationRegistry {
            for poolFile in variation.pool {
                allFiles.insert(poolFile)
            }
        }

        for file in allFiles {
            if let url = resolveAudioFile(file) {
                resolvedURLs[file] = url
                do {
                    let resource = try AudioFileResource.load(contentsOf: url)
                    preloadedResources[file] = resource
                    loadedCount += 1
                    logger.debug("Preloaded audio: \(file)")
                } catch {
                    failedFiles.append((file: file, error: error.localizedDescription))
                    logger.error("Failed to preload \(file): \(error.localizedDescription)")
                }
            } else {
                missingFiles.append(file)
                logger.error("Audio file missing from Media.bundle: \(file)")
            }
        }

        let report = AudioPreloadReport(
            totalFiles: allFiles.count,
            loadedFiles: loadedCount,
            missingFiles: missingFiles,
            failedFiles: failedFiles
        )

        if report.isComplete {
            logger.info("Audio preload complete: \(loadedCount)/\(allFiles.count) files loaded")
        } else {
            logger.error("Audio preload incomplete: \(loadedCount)/\(allFiles.count) loaded, \(missingFiles.count) missing, \(failedFiles.count) failed")
        }

        return report
    }

    // MARK: - Sound Variations (2B)

    public func registerVariation(_ key: String, pool: [String], mode: SelectionMode) {
        variationRegistry[key] = SoundVariation(pool: pool, mode: mode)
        variationIndices[key] = 0
        if mode == .shuffle {
            variationShuffleOrders[key] = Array(0..<pool.count).shuffled()
        }
        logger.info("Registered variation '\(key)' with \(pool.count) files, mode=\(mode.rawValue)")
    }

    private func resolveVariation(for file: String) -> String {
        guard let variation = variationRegistry[file], !variation.pool.isEmpty else {
            return file
        }

        switch variation.mode {
        case .random:
            return variation.pool.randomElement() ?? file

        case .sequential:
            let index = variationIndices[file, default: 0]
            let resolved = variation.pool[index % variation.pool.count]
            variationIndices[file] = index + 1
            return resolved

        case .shuffle:
            var order = variationShuffleOrders[file] ?? Array(0..<variation.pool.count).shuffled()
            var index = variationIndices[file, default: 0]
            if index >= order.count {
                order = Array(0..<variation.pool.count).shuffled()
                variationShuffleOrders[file] = order
                index = 0
            }
            let resolved = variation.pool[order[index]]
            variationIndices[file] = index + 1
            return resolved
        }
    }

    // MARK: - Volume Pipeline (1A + 3B)

    public func categoryForChannel(_ channel: String, explicitCategory: String? = nil) -> String {
        if let explicit = explicitCategory { return explicit }
        if let cached = channelCategories[channel] { return cached }
        // Derive from channel name prefix
        if channel.hasPrefix("ambient") { return "ambient" }
        if channel.hasPrefix("scene_audio") { return "scene_audio" }
        if channel.hasPrefix("sfx") { return "sfx" }
        if channel.hasPrefix("narration") { return "narration" }
        if channel.hasPrefix("video") || channel.hasPrefix("main_video") { return "video" }
        return "sfx" // default
    }

    private func effectiveVolume(requested: Float, channel: String) -> Float {
        let busId = busForChannel(channel)
        let busVol = buses[busId]?.volume ?? 1.0
        let category = categoryForChannel(channel)
        let categoryVol = mixState.categoryVolumes[category] ?? 1.0
        let duckMul = duckMultipliers[channel] ?? 1.0
        // Authored volume automation rides here, as one more multiplier in the
        // existing pipeline rather than a competing notion of "how loud". It
        // is 1.0 for every channel in a document with no automation.
        let automation = automationMultipliers[channel] ?? 1.0
        return requested * busVol * categoryVol * mixState.masterVolume * duckMul * automation
    }

    // MARK: - Sequence volume automation

    /// Per-channel multiplier sampled from the sequence's `audioTracks`.
    /// Mirrors `duckMultipliers`: one more factor in `effectiveVolume`, so
    /// automation composes with buses, categories and ducking instead of
    /// fighting them.
    private var automationMultipliers: [String: Float] = [:]
    private var audioAutomationTracks: [AudioAutomationTrack] = []
    /// Authored fades per channel, in force for the current sequence.
    ///
    /// A fade used to be a SECOND WRITER of `node.volume`: `fadeVolume` ramped
    /// it on its own 30 Hz task while `applyMixToAllChannels` wrote the same
    /// property from the 20 Hz automation task and cancelled that ramp. Two
    /// writers with no order meant a fade crossing a volume key produced a
    /// different result depending on which fired last.
    ///
    /// Now a fade is DATA the one sampler evaluates, through
    /// `AudioGainComposition` — the same function the Mac preview calls. One
    /// writer, one rule, no race.
    private var audioFades: [String: [AudioFade]] = [:]
    private var audioAutomationClock: (@MainActor () -> TimeInterval)?
    private var audioAutomationTask: Task<Void, Never>?

    /// Bind the sequence's automation. Sampling only runs while a sequence
    /// actually carries keys, so an un-automated chapter pays nothing.
    public func setSequenceAudioAutomation(
        tracks: [AudioAutomationTrack],
        clock: (@MainActor () -> TimeInterval)?,
        fades: [String: [AudioFade]] = [:]
    ) {
        audioAutomationTask?.cancel()
        audioAutomationTask = nil
        audioAutomationTracks = tracks
        audioAutomationClock = clock
        audioFades = fades

        // Fades count as automation: a sequence with a fade and no curves
        // still needs the sampler running, or the fade never happens.
        guard SequenceAudioAutomation.hasAutomation(tracks) || !audioFades.isEmpty,
              clock != nil else {
            // Release every channel back to unity, or a sequence WITHOUT
            // automation would inherit the last ride of the one before it.
            if !automationMultipliers.isEmpty {
                automationMultipliers.removeAll()
                applyMixToAllChannels()
            }
            return
        }

        // 20 Hz. Volume automation is a control signal, not audio-rate: the
        // node volumes this drives are already smoothed, and sampling per
        // frame would burn main-thread time for a ride nobody can hear the
        // difference in.
        audioAutomationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleAudioAutomation()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func sampleAudioAutomation() {
        guard let clock = audioAutomationClock else { return }
        let time = clock()
        var changed = false
        // Every channel that currently has a voice, so the master bus reaches
        // channels with no track of their own.
        let channels = Set(ambientChannels.keys).union(spatialChannels.keys)
        for channel in channels {
            // THE ONE RULE. `volumeMultiplier` alone ignored fades; folding
            // them in here is what removes the second writer.
            //
            // Expressed as a MULTIPLIER against the channel's base level so it
            // slots into the existing mix pipeline unchanged — `effectiveVolume`
            // still multiplies bus, category, master and ducking around it.
            let base = ambientChannels[channel]?.targetVolume
                ?? spatialChannels[channel]?.targetVolume ?? 1.0
            let composed = AudioGainComposition.authoredGain(
                base: base,
                fades: audioFades[channel] ?? [],
                channel: channel,
                at: time,
                in: audioAutomationTracks
            )
            let value = base > 0.0001 ? composed / base : composed
            // Only write on a real change: this runs 20x a second and each
            // write touches an AVAudioPlayerNode.
            if abs((automationMultipliers[channel] ?? 1.0) - value) > 0.001 {
                automationMultipliers[channel] = value
                changed = true
            }
        }
        if changed { applyMixToAllChannels() }
    }

    private func applyMixToAllChannels() {
        for (channel, ch) in ambientChannels {
            let target = effectiveVolume(requested: ch.targetVolume, channel: channel)
            fadeNodeVolume(channel: channel, to: ch.targetVolume, duration: 0.3, rawTarget: target)
        }
        for (channel, ch) in spatialChannels {
            let vol = effectiveVolume(requested: ch.targetVolume, channel: channel)
            ch.controller?.gain = Audio.Decibel(volumeToDecibels(vol))
        }
    }

    // MARK: - Channel State (1B)

    public func channelState(_ channel: String) -> ChannelState? {
        if let ch = ambientChannels[channel] {
            let sampleRate = ch.audioFile.processingFormat.sampleRate
            let duration = sampleRate > 0 ? Double(ch.audioFile.length) / sampleRate : 0
            var currentTime: TimeInterval = 0
            if ch.playerNode.isPlaying,
               let nodeTime = ch.playerNode.lastRenderTime,
               nodeTime.isSampleTimeValid,
               let playerTime = ch.playerNode.playerTime(forNodeTime: nodeTime) {
                currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
                if ch.isLooping && duration > 0 {
                    currentTime = currentTime.truncatingRemainder(dividingBy: duration)
                }
            }
            let progress = duration > 0 ? currentTime / duration : 0
            return ChannelState(
                channel: channel,
                file: ch.file,
                isPlaying: ch.playerNode.isPlaying,
                currentTime: currentTime,
                duration: duration,
                progress: progress
            )
        }
        if let ch = spatialChannels[channel] {
            let elapsed = Date.now.timeIntervalSince(ch.startTime)
            let progress = ch.duration > 0 ? min(elapsed / ch.duration, 1.0) : 0
            return ChannelState(
                channel: channel,
                file: ch.file,
                isPlaying: ch.controller != nil,
                currentTime: elapsed,
                duration: ch.duration,
                progress: progress
            )
        }
        return nil
    }

#if DEBUG
    public func debugAmbientVolume(_ channel: String) -> Float? {
        ambientChannels[channel]?.playerNode.volume
    }
#endif

    // MARK: - Audio Zone Management (3A)

    public func addAudioZone(_ zone: AudioZone) {
        zones[zone.id] = zone
        logger.info("Added audio zone: \(zone.id) at \(zone.center), radius=\(zone.radius)")
        // Immediately check if listener is already in zone
        processZones()
    }

    public func removeAudioZone(id: String) {
        zones.removeValue(forKey: id)
        if let channelName = activeZoneChannels.removeValue(forKey: id) {
            stopAmbient(channel: channelName)
        }
        logger.info("Removed audio zone: \(id)")
    }

    public func removeAllAudioZones() {
        for (_, channelName) in activeZoneChannels {
            stopAmbient(channel: channelName)
        }
        zones.removeAll()
        activeZoneChannels.removeAll()
        logger.info("Removed all audio zones")
    }

    public func updateListenerPosition(_ position: SIMD3<Float>) {
        listenerPosition = position
        processZones()
    }

    private func processZones() {
        for (zoneId, zone) in zones {
            let distance = simd_distance(listenerPosition, zone.center)
            let isInZone = distance <= zone.radius
            let wasActive = activeZoneChannels[zoneId] != nil

            if isInZone && !wasActive {
                // Enter zone — start playing
                let channelName = "zone_\(zoneId)"
                let zoneAction = AudioAction(
                    file: zone.audio.file,
                    channel: channelName,
                    volume: zone.audio.volume,
                    loop: zone.audio.loop,
                    fadeIn: zone.fadeInDuration,
                    spatial: zone.audio.spatial,
                    category: zone.audio.category ?? "ambient",
                    crossfade: zone.audio.crossfade,
                    loopConfig: zone.audio.loopConfig
                )
                play(action: zoneAction)
                activeZoneChannels[zoneId] = channelName
                logger.info("Entered audio zone: \(zoneId)")

            } else if isInZone && wasActive {
                // Inside zone — adjust volume based on distance falloff
                guard let channelName = activeZoneChannels[zoneId] else { continue }
                let volumeMultiplier: Float
                if distance <= zone.falloffStart {
                    volumeMultiplier = 1.0
                } else {
                    let range = zone.radius - zone.falloffStart
                    let t = range > 0 ? (distance - zone.falloffStart) / range : 1.0
                    volumeMultiplier = max(0, 1.0 - t)
                }
                if var ch = ambientChannels[channelName] {
                    let baseVolume = zone.audio.volume * volumeMultiplier
                    let effective = effectiveVolume(requested: baseVolume, channel: channelName)
                    ch.playerNode.volume = effective
                    ch.targetVolume = baseVolume
                    ambientChannels[channelName] = ch
                }

            } else if !isInZone && wasActive {
                // Exit zone — fade out and stop
                guard let channelName = activeZoneChannels[zoneId] else { continue }
                fadeVolume(channel: channelName, to: 0, duration: zone.fadeOutDuration)
                activeZoneChannels.removeValue(forKey: zoneId)
                logger.info("Exited audio zone: \(zoneId)")
            }
        }
    }

    // MARK: - Playback

    public func play(action: AudioAction, stepContext: String? = nil) {
        // Set channel category if explicit
        if let category = action.category {
            channelCategories[action.channel] = category
        }

        // ROUTE FIRST, THEN LOOP — the order matters and it used to be wrong.
        //
        // `loopConfig` returned before any routing decision, so a cue with an
        // intro/loop/outro was ALWAYS unspatialised: a positional looped sound
        // played from nowhere and an encoded master was flattened. Looping is a
        // property of how a source repeats, not of where it plays, so the route
        // is chosen first and each path applies its own looping.
        //
        // ROUTE ON THE AUTHORED PLAYBACK MODEL, not on `spatial != nil`.
        //
        // That boolean answers "is there attachment metadata", which is not the
        // same question as "what are the playback semantics". Routing on it
        // sent head-locked stereo, an ambisonic bed and an Apple Spatial Audio
        // master down one path indistinguishably.
        //
        // `AudioRuntimeRouting` is the one decision and it is shared with the
        // editor, so what an author is told and what the runtime does cannot
        // drift. A `fallback` is a DECLARED degradation with a reason, not a
        // silent detour — it is logged once per channel below.
        let routing = action.routing
        if case .fallback(_, let from, let reason) = routing {
            reportFallback(model: from, reason: reason, channel: action.channel, file: action.file)
        }

        switch routing.route {
        case .positional:
            // PIPELINE A — a source in the scene. Its location is the emitter's
            // animated transform and nothing here duplicates it.
            if let loopConfig = action.loopConfig {
                // The three-file intro/loop/outro form has no spatial variant.
                // Declared, not silent — and now reached only for a cue that
                // genuinely asked for both.
                reportFallback(
                    model: .positional,
                    reason: "Cues with an intro/loop/outro play unspatialised. Use a plain looping cue to place this sound.",
                    channel: action.channel, file: action.file)
                playWithLoopConfig(action: action, loopConfig: loopConfig, stepContext: stepContext)
            } else {
                playSpatial(action: action, stepContext: stepContext)
            }

        case .systemSpatialMedia:
            // PIPELINE B — an encoded master, handed over whole. `loopConfig`'s
            // three-file form is a graph construct and has no meaning here; a
            // plain `loop` does, and the system player handles it.
            playSystemSpatialMedia(action: action, stepContext: stepContext)

        case .headLocked, .sceneBased:
            // Scene-based still degrades to here, declared, until its source
            // can be prepared into something a pipeline can carry. Listed
            // rather than defaulted so giving it a path is a compile error
            // here rather than a silent continuation.
            if let loopConfig = action.loopConfig {
                playWithLoopConfig(action: action, loopConfig: loopConfig, stepContext: stepContext)
            } else {
                playAmbient(action: action, stepContext: stepContext)
            }
        }
        applyDucking(forTriggerChannel: action.channel)
    }

    /// Say once, per channel, that a cue is not being played as authored.
    ///
    /// Once — an author scrubbing a Sequence would otherwise get the same line
    /// on every replay of the same cue, and a log nobody reads is the same as
    /// no log. The document is unchanged either way: the authored intent is
    /// preserved and only this playback is degraded.
    private func reportFallback(
        model: AudioPlaybackModel, reason: String, channel: String, file: String
    ) {
        guard reportedFallbackChannels.insert(channel).inserted else { return }
        logger.warning("""
            Audio '\(file, privacy: .public)' on channel '\(channel, privacy: .public)' is \
            authored as \(model.rawValue, privacy: .public) but is playing head-locked. \
            \(reason, privacy: .public)
            """)
    }

    /// PIPELINE B entry — hand the encoded asset to the system player.
    ///
    /// The gain is composed HERE, by the same `effectiveVolume` every other
    /// path uses, so bus / category / master / ducking apply identically. What
    /// is NOT possible is routing an encoded master through the bus EFFECT
    /// chain: those are `AVAudioUnit`s in the engine graph, and putting the
    /// asset through the graph is precisely what destroys it. Level yes,
    /// insert effects no — documented rather than forced.
    private func playSystemSpatialMedia(action: AudioAction, stepContext: String? = nil) {
        let resolvedFile = resolveVariation(for: action.file)
        guard let url = findAudioURL(file: resolvedFile) else {
            logger.error("""
                Spatial media DROPPED — file: \(resolvedFile, privacy: .public), \
                channel: \(action.channel, privacy: .public), \
                beat: \(stepContext ?? "unknown", privacy: .public)
                """)
            return
        }
        systemSpatialMedia.play(
            action: action,
            url: url,
            effectiveVolume: effectiveVolume(requested: action.volume, channel: action.channel),
            presentation: action.spatialPresentation ?? .headTracked
        )
    }

    private func playAmbient(action: AudioAction, stepContext: String? = nil) {
        // MARK: Prewarm hit path (spec 038)
        // Check before resolveVariation to avoid double-advancing variation indices.
        // IMPORTANT: do NOT call applyDucking() here — play(action:) calls it after playAmbient returns.
        // Calling it inside here would double-count duckTriggerCount and leave channels over-ducked.
        if let prewarmed = prewarmedChannels.removeValue(forKey: action.channel) {
#if DEBUG
            // Per-channel tag allows R1/R7 per-channel measurement in Instruments.
            let _hitState = audioSignposter.beginInterval("prewarm_hit", "\(action.channel, privacy: .private)")
#endif
            // Manual eviction of old occupant — do NOT call stopAmbient() which fires onChannelStopped
            // and would corrupt protectedChannels for .ambient-scoped channels.
            if let old = ambientChannels.removeValue(forKey: action.channel) {
                old.fadeTask?.cancel()
                old.outgoingFadeTask?.cancel()
                if let outgoing = old.outgoingPlayerNode { cleanupPlayerNode(outgoing) }
                cleanupPlayerNode(old.playerNode)
                // onChannelStopped intentionally NOT called — channel is being replaced, not removed;
                // AudioActionExecutor.play() already updated protectedChannels before calling us.
            }
            if let category = action.category {
                channelCategories[action.channel] = category
            }
            ensureEngineRunning()
            let vol = effectiveVolume(requested: action.volume, channel: action.channel)
            if let fadeIn = action.fadeIn, fadeIn > 0 {
                prewarmed.playerNode.volume = 0
                prewarmed.playerNode.play()
                ambientChannels[action.channel] = prewarmed
                fadeVolume(channel: action.channel, to: action.volume, duration: fadeIn)
            } else {
                prewarmed.playerNode.volume = vol
                prewarmed.playerNode.play()
                ambientChannels[action.channel] = prewarmed
            }
#if DEBUG
            audioSignposter.endInterval("prewarm_hit", _hitState)
#endif
            logger.info("Prewarm hit: \(prewarmed.file) on '\(action.channel)' (beat: \(stepContext ?? "?"))")
            // NOTE: do NOT call applyDucking here — play(action:) handles it after we return.
            return
        }

        let resolvedFile = resolveVariation(for: action.file)

        // Crossfade (2A) — if channel is occupied and crossfade is set
        if let crossfadeDuration = action.crossfade, crossfadeDuration > 0,
           ambientChannels[action.channel] != nil {
            crossfadeAmbient(action: action, resolvedFile: resolvedFile, duration: crossfadeDuration, stepContext: stepContext)
            return
        }

        // Stop existing channel (hard stop)
        stopAmbient(channel: action.channel)

        guard let url = findAudioURL(file: resolvedFile) else {
            logger.error("Ambient audio DROPPED — file: \(resolvedFile), channel: \(action.channel), beat: \(stepContext ?? "unknown")")
            return
        }

        do {
#if DEBUG
            let _fileState = audioSignposter.beginInterval("ambient_file_open")
#endif
            let audioFile = try AVAudioFile(forReading: url)
#if DEBUG
            audioSignposter.endInterval("ambient_file_open", _fileState)
#endif
            let playerNode = AVAudioPlayerNode()
            let busId = busForChannel(action.channel)

            ensureEngineRunning()
#if DEBUG
            let _attachState = audioSignposter.beginInterval("ambient_attach")
#endif
            audioEngine.attach(playerNode)
            connectPlayerToBus(playerNode, format: audioFile.processingFormat, busId: busId)
#if DEBUG
            audioSignposter.endInterval("ambient_attach", _attachState)
            attachCallCount += 1
#endif

            let vol = effectiveVolume(requested: action.volume, channel: action.channel)

            if action.loop {
                let buffer = try loadBuffer(from: audioFile, sourceRange: action.sourceRange)
                playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            } else {
                scheduleAmbientFile(playerNode, file: audioFile, channel: action.channel,
                                    sourceRange: action.sourceRange)
            }

            ambientChannels[action.channel] = AmbientChannel(
                playerNode: playerNode,
                audioFile: audioFile,
                targetVolume: action.volume,
                file: resolvedFile,
                isLooping: action.loop,
                busId: busId
            )

            if let fadeIn = action.fadeIn, fadeIn > 0 {
                playerNode.volume = 0
                playerNode.play()
                fadeVolume(channel: action.channel, to: action.volume, duration: fadeIn)
            } else {
                playerNode.volume = vol
                playerNode.play()
            }
            logger.info("Playing ambient: \(resolvedFile) on channel '\(action.channel)' (bus: \(busId))")
        } catch {
            logger.error("Failed to play \(resolvedFile): \(error.localizedDescription)")
        }
    }

    // MARK: - AVAudioEngine Scheduling Helpers (3B)

    private func scheduleAmbientFile(
        _ node: AVAudioPlayerNode,
        file: AVAudioFile,
        channel: String,
        sourceRange: MediaSourceRange = .full
    ) {
        let completion: (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let ch = self.ambientChannels[channel], ch.playerNode === node else { return }
                self.handleAmbientFinished(channel: channel)
            }
        }
        // A marked cue schedules only its window. `scheduleSegment` is the
        // whole reason audio ranges are cheap here — the node plays frames
        // [in, out) and reports completion at the OUT point, so a clip that
        // ends at source 12 fires `onAudioComplete` at 12 rather than at the
        // end of a three-minute master.
        if let sequence = frameRange(of: sourceRange, in: file) {
            node.scheduleSegment(file,
                                 startingFrame: sequence.start,
                                 frameCount: sequence.count,
                                 at: nil,
                                 completionCallbackType: .dataPlayedBack,
                                 completionHandler: completion)
        } else {
            node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack,
                              completionHandler: completion)
        }
    }

    /// The marked window as whole sample frames, or nil for "the whole file".
    ///
    /// Seconds → frames uses the file's OWN sample rate, not the engine's:
    /// a 48 kHz master inside a 44.1 kHz graph would otherwise seek to the
    /// wrong place, and the error scales with how far into the file the mark
    /// is — the classic "it's fine at the start and drifts later" bug.
    ///
    /// Returns nil rather than a full-file range so the untouched path stays
    /// `scheduleFile`, exactly as before this feature existed.
    private func frameRange(
        of range: MediaSourceRange,
        in file: AVAudioFile
    ) -> (start: AVAudioFramePosition, count: AVAudioFrameCount)? {
        guard range.isMarked else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }

        let masterDuration = Double(file.length) / rate
        let start = min(max(0, range.resolvedIn), masterDuration)
        let end = range.resolvedOut(masterDuration: masterDuration) ?? masterDuration

        let startFrame = AVAudioFramePosition((start * rate).rounded())
        let endFrame = AVAudioFramePosition((min(end, masterDuration) * rate).rounded())
        guard endFrame > startFrame, startFrame < file.length else { return nil }
        let count = AVAudioFrameCount(min(endFrame, file.length) - startFrame)
        guard count > 0 else { return nil }
        return (startFrame, count)
    }

    //  INTRO / LOOP / OUTRO CUES DELIBERATELY IGNORE THE PARENT'S RANGE.
    //
    //  `loopConfig` names three SEPARATE files. A source range marked on the
    //  `playAudio` describes a window into `action.file`, which is not any of
    //  them — applying it to `loop.wav` would cut a window out of the wrong
    //  master and produce a loop the author never marked. Those three
    //  scheduling sites therefore stay whole-file on purpose; if per-sequence
    //  trimming of an intro/loop/outro is ever wanted it needs its own marks,
    //  not a borrowed one.

    private func handleAmbientFinished(channel: String) {
        // Handle loop state transitions (2C)
        if let state = loopStates[channel] {
            switch state.phase {
            case .playingIntro:
                // Intro finished naturally — transition task may have already started loop
                break
            case .playingOutro:
                loopStates.removeValue(forKey: channel)
                stopAmbient(channel: channel)
                logger.info("Loop outro complete on '\(channel)'")
            default:
                break
            }
        }

        onChannelFinished?(channel)
    }

    /// Load the frames a looping cue should repeat.
    ///
    /// With a marked range this reads ONLY the window, so
    /// `scheduleBuffer(options: .loops)` loops the selection rather than the
    /// whole master — the buffer IS the loop, so there is no second place
    /// where looping could disagree about its boundaries.
    private func loadBuffer(
        from audioFile: AVAudioFile,
        sourceRange: MediaSourceRange = .full
    ) throws -> AVAudioPCMBuffer {
        let sequence = frameRange(of: sourceRange, in: audioFile)
        let frameCount = sequence?.count ?? AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                            frameCapacity: frameCount) else {
            throw NSError(domain: "SpatialAudioManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }
        if let sequence {
            // `read(into:frameCount:)` reads from the file's current
            // position, so the seek must happen first. No need to restore it:
            // each cue opens its own AVAudioFile.
            audioFile.framePosition = sequence.start
            try audioFile.read(into: buffer, frameCount: sequence.count)
        } else {
            try audioFile.read(into: buffer)
        }
        return buffer
    }

    // MARK: - Crossfade (2A) — AVAudioEngine version

    private func crossfadeAmbient(action: AudioAction, resolvedFile: String, duration: TimeInterval, stepContext: String? = nil) {
        guard var existing = ambientChannels[action.channel] else { return }

        // Cancel any in-progress outgoing fade
        existing.outgoingFadeTask?.cancel()
        if let outgoing = existing.outgoingPlayerNode {
            cleanupPlayerNode(outgoing)
        }

        // Current player becomes outgoing
        let outgoingNode = existing.playerNode
        existing.fadeTask?.cancel()

        guard let url = findAudioURL(file: resolvedFile) else {
            logger.error("Crossfade audio DROPPED — file: \(resolvedFile), channel: \(action.channel), beat: \(stepContext ?? "unknown")")
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let newNode = AVAudioPlayerNode()
            let busId = existing.busId

            ensureEngineRunning()
            audioEngine.attach(newNode)
            connectPlayerToBus(newNode, format: audioFile.processingFormat, busId: busId)

            if action.loop {
                let buffer = try loadBuffer(from: audioFile, sourceRange: action.sourceRange)
                newNode.scheduleBuffer(buffer, at: nil, options: .loops)
            } else {
                scheduleAmbientFile(newNode, file: audioFile, channel: action.channel,
                                    sourceRange: action.sourceRange)
            }

            newNode.volume = 0
            newNode.play()

            let targetVol = effectiveVolume(requested: action.volume, channel: action.channel)

            // Fade outgoing to 0
            let outgoingFadeTask = Task { @MainActor [self] in
                await self.animateFade(node: outgoingNode, from: outgoingNode.volume, to: 0, duration: duration)
                guard !Task.isCancelled else { return }
                self.cleanupPlayerNode(outgoingNode)
                if var ch = self.ambientChannels[action.channel] {
                    ch.outgoingPlayerNode = nil
                    ch.outgoingFadeTask = nil
                    self.ambientChannels[action.channel] = ch
                }
            }

            // Fade incoming to target
            let incomingFadeTask = Task { @MainActor [self] in
                await self.animateFade(node: newNode, from: 0, to: targetVol, duration: duration)
            }

            existing.outgoingPlayerNode = outgoingNode
            existing.outgoingFadeTask = outgoingFadeTask
            existing.playerNode = newNode
            existing.audioFile = audioFile
            existing.targetVolume = action.volume
            existing.fadeTask = incomingFadeTask
            existing.file = resolvedFile
            existing.isLooping = action.loop
            ambientChannels[action.channel] = existing

            logger.info("Crossfading to \(resolvedFile) on '\(action.channel)' over \(duration)s")
        } catch {
            logger.error("Failed to create crossfade player for \(resolvedFile): \(error.localizedDescription)")
        }
    }

    private func animateFade(node: AVAudioPlayerNode, from startVol: Float, to endVol: Float, duration: TimeInterval) async {
        let steps = max(Int(duration * 30), 1)
        let stepDuration = duration / Double(steps)
        let volumeStep = (endVol - startVol) / Float(steps)

        for i in 0..<steps {
            guard !Task.isCancelled else { break }
            node.volume = startVol + volumeStep * Float(i + 1)
            try? await Task.sleep(for: .seconds(stepDuration))
        }
        if !Task.isCancelled {
            node.volume = endVol
        }
    }

    // MARK: - Loop Config (2C)

    private func playWithLoopConfig(action: AudioAction, loopConfig: LoopConfig, stepContext: String? = nil) {
        // Clean up any existing loop state
        cancelLoopState(channel: action.channel)
        stopAmbient(channel: action.channel)

        if let introFile = loopConfig.intro {
            // Play intro, then transition to loop
            let resolvedIntro = resolveVariation(for: introFile)
            guard let url = findAudioURL(file: resolvedIntro) else {
                logger.error("Loop intro DROPPED — file: \(resolvedIntro), channel: \(action.channel), beat: \(stepContext ?? "unknown")")
                startLoopPhase(action: action, loopConfig: loopConfig, stepContext: stepContext)
                return
            }

            do {
                let audioFile = try AVAudioFile(forReading: url)
                let playerNode = AVAudioPlayerNode()
                let busId = busForChannel(action.channel)

                ensureEngineRunning()
                audioEngine.attach(playerNode)
                connectPlayerToBus(playerNode, format: audioFile.processingFormat, busId: busId)

                scheduleAmbientFile(playerNode, file: audioFile, channel: action.channel)

                let sampleRate = audioFile.processingFormat.sampleRate
                let introDuration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0

                ambientChannels[action.channel] = AmbientChannel(
                    playerNode: playerNode,
                    audioFile: audioFile,
                    targetVolume: action.volume,
                    file: resolvedIntro,
                    isLooping: false,
                    busId: busId
                )

                let vol = effectiveVolume(requested: action.volume, channel: action.channel)
                if let fadeIn = action.fadeIn, fadeIn > 0 {
                    playerNode.volume = 0
                    playerNode.play()
                    fadeVolume(channel: action.channel, to: action.volume, duration: fadeIn)
                } else {
                    playerNode.volume = vol
                    playerNode.play()
                }

                // Schedule transition to loop near end of intro
                let transitionTask = Task { @MainActor [self] in
                    let waitTime = max(introDuration - loopConfig.crossfade, 0)
                    try? await Task.sleep(for: .seconds(waitTime))
                    guard !Task.isCancelled else { return }
                    self.startLoopPhase(action: action, loopConfig: loopConfig, stepContext: stepContext)
                }

                loopStates[action.channel] = LoopState(
                    config: loopConfig,
                    phase: .playingIntro,
                    transitionTask: transitionTask,
                    stepContext: stepContext
                )

                logger.info("Loop intro: \(resolvedIntro) on '\(action.channel)'")
            } catch {
                logger.error("Failed to play intro \(resolvedIntro): \(error.localizedDescription)")
                startLoopPhase(action: action, loopConfig: loopConfig, stepContext: stepContext)
            }
        } else {
            startLoopPhase(action: action, loopConfig: loopConfig, stepContext: stepContext)
        }
    }

    private func startLoopPhase(action: AudioAction, loopConfig: LoopConfig, stepContext: String? = nil) {
        let resolvedLoop = resolveVariation(for: loopConfig.loop)

        // Use crossfade if intro was playing
        if ambientChannels[action.channel] != nil && loopConfig.crossfade > 0 {
            let loopAction = AudioAction(
                file: resolvedLoop,
                channel: action.channel,
                volume: action.volume,
                loop: true,
                crossfade: loopConfig.crossfade
            )
            crossfadeAmbient(action: loopAction, resolvedFile: resolvedLoop, duration: loopConfig.crossfade, stepContext: stepContext)
        } else {
            stopAmbient(channel: action.channel)
            guard let url = findAudioURL(file: resolvedLoop) else {
                logger.error("Loop audio DROPPED — file: \(resolvedLoop), channel: \(action.channel), beat: \(stepContext ?? "unknown")")
                return
            }
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let playerNode = AVAudioPlayerNode()
                let busId = busForChannel(action.channel)

                ensureEngineRunning()
                audioEngine.attach(playerNode)
                connectPlayerToBus(playerNode, format: audioFile.processingFormat, busId: busId)

                let buffer = try loadBuffer(from: audioFile)
                playerNode.scheduleBuffer(buffer, at: nil, options: .loops)

                let vol = effectiveVolume(requested: action.volume, channel: action.channel)
                playerNode.volume = vol
                playerNode.play()

                ambientChannels[action.channel] = AmbientChannel(
                    playerNode: playerNode,
                    audioFile: audioFile,
                    targetVolume: action.volume,
                    file: resolvedLoop,
                    isLooping: true,
                    busId: busId
                )
            } catch {
                logger.error("Failed to play loop \(resolvedLoop): \(error.localizedDescription)")
                return
            }
        }

        if var state = loopStates[action.channel] {
            state.phase = .looping
            state.transitionTask = nil
            loopStates[action.channel] = state
        } else {
            loopStates[action.channel] = LoopState(config: loopConfig, phase: .looping, stepContext: stepContext)
        }
        logger.info("Loop phase: looping on '\(action.channel)'")
    }

    private func playOutro(channel: String) {
        guard var state = loopStates[channel] else { return }
        guard let outroFile = state.config.outro else {
            // No outro — just stop
            loopStates.removeValue(forKey: channel)
            stopAmbient(channel: channel)
            return
        }

        let resolvedOutro = resolveVariation(for: outroFile)
        let targetVolume = ambientChannels[channel]?.targetVolume ?? 1.0

        if ambientChannels[channel] != nil && state.config.crossfade > 0 {
            let outroAction = AudioAction(
                file: resolvedOutro,
                channel: channel,
                volume: targetVolume,
                loop: false,
                crossfade: state.config.crossfade
            )
            crossfadeAmbient(action: outroAction, resolvedFile: resolvedOutro, duration: state.config.crossfade, stepContext: state.stepContext)
        } else {
            stopAmbient(channel: channel)
            guard let url = findAudioURL(file: resolvedOutro) else {
                logger.error("Outro audio DROPPED — file: \(resolvedOutro), channel: \(channel), beat: \(state.stepContext ?? "unknown")")
                loopStates.removeValue(forKey: channel)
                return
            }
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let playerNode = AVAudioPlayerNode()
                let busId = busForChannel(channel)

                ensureEngineRunning()
                audioEngine.attach(playerNode)
                connectPlayerToBus(playerNode, format: audioFile.processingFormat, busId: busId)

                scheduleAmbientFile(playerNode, file: audioFile, channel: channel)

                let vol = effectiveVolume(requested: targetVolume, channel: channel)
                playerNode.volume = vol
                playerNode.play()

                ambientChannels[channel] = AmbientChannel(
                    playerNode: playerNode,
                    audioFile: audioFile,
                    targetVolume: targetVolume,
                    file: resolvedOutro,
                    isLooping: false,
                    busId: busId
                )
            } catch {
                logger.error("Failed to play outro \(resolvedOutro): \(error.localizedDescription)")
                loopStates.removeValue(forKey: channel)
                return
            }
        }

        state.phase = .playingOutro
        state.transitionTask = nil
        loopStates[channel] = state
        logger.info("Loop phase: outro on '\(channel)'")
    }

    private func cancelLoopState(channel: String) {
        if let state = loopStates.removeValue(forKey: channel) {
            state.transitionTask?.cancel()
        }
    }

    private func playSpatial(action: AudioAction, stepContext: String? = nil) {
        stopSpatial(channel: action.channel)

        let sourceEntity = Entity()
        sourceEntity.name = "AudioSource_\(action.channel)"

        if let config = action.spatial {
            if let targetName = config.attachToEntity,
               let targetEntity = entityLookup?(targetName) {
                targetEntity.addChild(sourceEntity)
                logger.info("Spatial audio attached to entity: \(targetName)")
            } else {
                if let pos = config.position {
                    sourceEntity.position = pos
                }
                audioRoot.addChild(sourceEntity)
            }
        } else {
            audioRoot.addChild(sourceEntity)
        }

        let resolvedFile = resolveVariation(for: action.file)

        if let resource = preloadedResources[resolvedFile] {
            let vol = effectiveVolume(requested: action.volume, channel: action.channel)
            let controller = sourceEntity.playAudio(resource)
            controller.gain = Audio.Decibel(volumeToDecibels(vol))

            spatialChannels[action.channel] = SpatialChannel(
                entity: sourceEntity,
                controller: controller,
                targetVolume: action.volume,
                file: resolvedFile,
                startTime: .now,
                duration: 0 // RealityKit doesn't expose duration easily
            )
            logger.info("Playing spatial: \(resolvedFile) on channel '\(action.channel)'")
        } else {
            let ctx = stepContext ?? "unknown"
            let wasPreloaded = resolvedURLs[resolvedFile] != nil
            logger.error("Spatial audio DROPPED — file: \(resolvedFile), channel: \(action.channel), beat: \(ctx). Not in preloadedResources.")
            if wasPreloaded {
                // Logic error: preload found this file but it's not in preloadedResources
                assertionFailure("Preloaded file vanished from preloadedResources: \(resolvedFile) — channel: \(action.channel), beat: \(ctx)")
            }
        }
    }

    // MARK: - Stop

    public func stop(channel: String) {
        // Pipeline B occurrences live in their own player; a channel stop must
        // reach both or an encoded master keeps playing under the next cue.
        systemSpatialMedia.stop(channel: channel)

        // If channel has a loop config, trigger outro instead of hard stop
        if let state = loopStates[channel], state.phase == .looping {
            playOutro(channel: channel)
            return
        }

        removeDucking(forTriggerChannel: channel)
        cancelLoopState(channel: channel)
        stopAmbient(channel: channel)
        stopSpatial(channel: channel)
    }

    /// Force stop — bypasses outro for immediate silence.
    public func forceStop(channel: String) {
        removeDucking(forTriggerChannel: channel)
        cancelLoopState(channel: channel)
        stopAmbient(channel: channel)
        stopSpatial(channel: channel)
    }

    private func stopAmbient(channel: String) {
        if let ch = ambientChannels.removeValue(forKey: channel) {
            ch.fadeTask?.cancel()
            ch.outgoingFadeTask?.cancel()
            if let outgoing = ch.outgoingPlayerNode {
                cleanupPlayerNode(outgoing)
            }
            cleanupPlayerNode(ch.playerNode)
            logger.debug("Stopped ambient channel: \(channel)")
            onChannelStopped?(channel)
        }
    }

    private func stopSpatial(channel: String) {
        if let ch = spatialChannels.removeValue(forKey: channel) {
            ch.controller?.stop()
            ch.entity.removeFromParent()
            logger.debug("Stopped spatial channel: \(channel)")
            onChannelStopped?(channel)
        }
    }

    public func stopAll(except protectedChannels: Set<String> = []) {
        for channel in systemSpatialMedia.activeChannels where !protectedChannels.contains(channel) {
            systemSpatialMedia.stop(channel: channel)
        }

        for key in ambientChannels.keys where !protectedChannels.contains(key) {
            removeDucking(forTriggerChannel: key)
        }
        for key in spatialChannels.keys where !protectedChannels.contains(key) {
            removeDucking(forTriggerChannel: key)
        }
        for key in ambientChannels.keys where !protectedChannels.contains(key) {
            cancelLoopState(channel: key)
            stopAmbient(channel: key)
        }
        for key in spatialChannels.keys where !protectedChannels.contains(key) {
            stopSpatial(channel: key)
        }
        for channel in duckedChannels where !protectedChannels.contains(channel) {
            preDuckVolumes.removeValue(forKey: channel)
            duckTriggerCount.removeValue(forKey: channel)
            duckMultipliers.removeValue(forKey: channel)
            duckedChannels.remove(channel)
        }
        // Clean up zone channels that aren't protected
        var zonesToRemove: [String] = []
        for (zoneId, channelName) in activeZoneChannels {
            if !protectedChannels.contains(channelName) {
                zonesToRemove.append(zoneId)
            }
        }
        for zoneId in zonesToRemove {
            activeZoneChannels.removeValue(forKey: zoneId)
        }
    }

    public func stopEverything() {
        for key in ambientChannels.keys {
            cancelLoopState(channel: key)
            stopAmbient(channel: key)
        }
        for key in spatialChannels.keys {
            stopSpatial(channel: key)
        }
        loopStates.removeAll()
        activeZoneChannels.removeAll()
        clearAllDuckingState()
        // Clear prewarm pool on full shutdown.
        // stopAll() intentionally does NOT clear this — prewarm must survive BeatEngine.play()’s
        // internal stop(resetEntities: false) → stopAll() call and reach beat 1.
        for (_, ch) in prewarmedChannels {
            ch.fadeTask?.cancel()
            cleanupPlayerNode(ch.playerNode)
        }
        prewarmedChannels.removeAll()
        audioEngine.stop()
    }

    // MARK: - Pause / Resume

    /// Pauses all ambient channel player nodes. Cancels active fade tasks but preserves channel state.
    /// Spatial channels (AudioPlaybackController) don't support pause — noted as a limitation.
    public func pauseAll() {
        // STATE CHANGE, not a per-frame seek. A gate, a transport pause and a
        // Timeline jump are events; the encoded player is told when one
        // happens and never polled for time.
        systemSpatialMedia.pauseAll()

        for key in ambientChannels.keys {
            guard var ch = ambientChannels[key] else { continue }
            ch.fadeTask?.cancel()
            ch.fadeTask = nil
            ch.playerNode.pause()
            ch.outgoingFadeTask?.cancel()
            ch.outgoingFadeTask = nil
            ch.outgoingPlayerNode?.pause()
            ambientChannels[key] = ch  // single write-back
        }
        for (_, channel) in spatialChannels {
            // AudioPlaybackController doesn't expose pause — mute as workaround.
            channel.controller?.gain = Audio.Decibel(volumeToDecibels(0))
        }
        logger.info("Paused all audio (\(self.ambientChannels.count) ambient, \(self.spatialChannels.count) spatial)")
    }

    /// Resumes all ambient channel player nodes from where they were paused.
    public func resumeAll() {
        systemSpatialMedia.resumeAll()

        for (_, channel) in ambientChannels {
            channel.playerNode.play()
            // Resume outgoing crossfade node if it was mid-transition
            channel.outgoingPlayerNode?.play()
        }
        for (channelKey, channel) in spatialChannels {
            let vol = effectiveVolume(requested: channel.targetVolume, channel: channelKey)
            channel.controller?.gain = Audio.Decibel(volumeToDecibels(vol))
        }
        logger.info("Resumed all audio (\(self.ambientChannels.count) ambient, \(self.spatialChannels.count) spatial)")
    }

    // MARK: - Fade

    /// Author a fade on `channel`.
    ///
    /// RECORDS AN ENVELOPE; it does not ramp anything itself. The 20 Hz
    /// automation sampler evaluates it through `AudioGainComposition`, which
    /// is the same function the Mac preview uses — so the editor and the
    /// device agree, and a fade crossing a volume key composes with it instead
    /// of racing it.
    ///
    /// Falls back to the old immediate ramp ONLY when there is no authored
    /// clock (a host driving audio outside a sequence), where there is no
    /// sampler to evaluate an envelope and nothing to race with.
    public func fade(channel: String, to targetVolume: Float, duration: TimeInterval) {
        guard let clock = audioAutomationClock else {
            fadeVolume(channel: channel, to: targetVolume, duration: duration)
            return
        }
        audioFades[channel, default: []].append(
            AudioFade(startTime: clock(), duration: duration, to: targetVolume)
        )
        // A sequence that had no automation at all has no sampler running yet.
        if audioAutomationTask == nil {
            setSequenceAudioAutomation(
                tracks: audioAutomationTracks, clock: audioAutomationClock, fades: audioFades
            )
        }
    }

    private func fadeVolume(channel: String, to targetVolume: Float, duration: TimeInterval, applyMix: Bool = true, rawTarget: Float? = nil) {
        // NARRATIVE MIXING STILL APPLIES TO AN ENCODED MASTER.
        //
        // Level, fades, master and ducking are an output gain — they do not
        // touch the spatial render, so a spatial mix fades like anything else.
        // What CANNOT apply is the bus EFFECT chain: those are `AVAudioUnit`s
        // in the engine graph, and putting the asset through the graph is
        // exactly what flattens it. Level yes, inserts no.
        if systemSpatialMedia.isActive(channel: channel) {
            fadeSystemSpatialVolume(
                channel: channel,
                to: rawTarget ?? (applyMix
                    ? effectiveVolume(requested: targetVolume, channel: channel)
                    : targetVolume),
                duration: duration)
            return
        }
        guard var ch = ambientChannels[channel] else { return }

        ch.fadeTask?.cancel()
        ch.targetVolume = targetVolume

        let effectiveTarget: Float
        if let raw = rawTarget {
            effectiveTarget = raw
        } else if applyMix {
            effectiveTarget = effectiveVolume(requested: targetVolume, channel: channel)
        } else {
            effectiveTarget = targetVolume
        }

        let node = ch.playerNode
        let startVolume = node.volume
        let steps = max(Int(duration * 30), 1)
        let stepDuration = duration / Double(steps)
        let volumeStep = (effectiveTarget - startVolume) / Float(steps)

        ch.fadeTask = Task { @MainActor [self] in
            for i in 0..<steps {
                guard !Task.isCancelled else { break }
                node.volume = startVolume + volumeStep * Float(i + 1)
                try? await Task.sleep(for: .seconds(stepDuration))
            }
            node.volume = effectiveTarget
            if effectiveTarget <= 0.001 {
                self.stopAmbient(channel: channel)
            }
        }

        ambientChannels[channel] = ch
    }

    /// Ramp an encoded master's output gain on the same schedule the graph
    /// path uses, so a fade sounds identical whichever pipeline carries it.
    private func fadeSystemSpatialVolume(channel: String, to target: Float, duration: TimeInterval) {
        systemSpatialFadeTasks[channel]?.cancel()
        guard duration > 0 else {
            systemSpatialMedia.setVolume(target, channel: channel)
            return
        }
        let start = systemSpatialMedia.volume(channel: channel) ?? target
        let steps = max(Int(duration * 30), 1)
        let stepDuration = duration / Double(steps)
        let delta = (target - start) / Float(steps)

        systemSpatialFadeTasks[channel] = Task { @MainActor [self] in
            for i in 0..<steps {
                guard !Task.isCancelled else { break }
                systemSpatialMedia.setVolume(start + delta * Float(i + 1), channel: channel)
                try? await Task.sleep(for: .seconds(stepDuration))
            }
            guard !Task.isCancelled else { return }
            systemSpatialMedia.setVolume(target, channel: channel)
            // A fade to silence ends the occurrence, exactly as it does on the
            // graph path — otherwise a faded-out master keeps a player alive.
            if target <= 0.001 { systemSpatialMedia.stop(channel: channel) }
        }
    }

    /// Fade variant for applyMixToAllChannels (avoids updating targetVolume).
    private func fadeNodeVolume(channel: String, to targetVolume: Float, duration: TimeInterval, rawTarget: Float) {
        guard var ch = ambientChannels[channel] else { return }

        ch.fadeTask?.cancel()

        let node = ch.playerNode
        let startVolume = node.volume
        let steps = max(Int(duration * 30), 1)
        let stepDuration = duration / Double(steps)
        let volumeStep = (rawTarget - startVolume) / Float(steps)

        ch.fadeTask = Task { @MainActor in
            for i in 0..<steps {
                guard !Task.isCancelled else { break }
                node.volume = startVolume + volumeStep * Float(i + 1)
                try? await Task.sleep(for: .seconds(stepDuration))
            }
            node.volume = rawTarget
        }

        ambientChannels[channel] = ch
    }

    // MARK: - Ducking

    private func applyDucking(forTriggerChannel trigger: String) {
        for rule in duckingRules where rule.trigger == trigger {
            for target in rule.targets {
                if let ambient = ambientChannels[target.channel] {
                    if preDuckVolumes[target.channel] == nil {
                        preDuckVolumes[target.channel] = ambient.targetVolume
                    }
                    duckedChannels.insert(target.channel)
                    duckTriggerCount[target.channel, default: 0] += 1
                    duckMultipliers[target.channel] = target.duckLevel
                    let duckedVolume = effectiveVolume(requested: preDuckVolumes[target.channel] ?? ambient.targetVolume, channel: target.channel)
                    fadeVolume(channel: target.channel, to: preDuckVolumes[target.channel] ?? ambient.targetVolume, duration: target.fadeInDuration, applyMix: false, rawTarget: duckedVolume)
                    logger.debug("Ducking '\(target.channel)' to \(duckedVolume) (trigger: \(trigger))")
                }
            }
        }
    }

    private func removeDucking(forTriggerChannel trigger: String) {
        for rule in duckingRules where rule.trigger == trigger {
            for target in rule.targets {
                guard duckedChannels.contains(target.channel) else { continue }
                let count = (duckTriggerCount[target.channel] ?? 1) - 1
                duckTriggerCount[target.channel] = count
                if count <= 0 {
                    duckMultipliers.removeValue(forKey: target.channel)
                    if let originalVolume = preDuckVolumes[target.channel] {
                        let restoredVol = effectiveVolume(requested: originalVolume, channel: target.channel)
                        fadeVolume(channel: target.channel, to: originalVolume, duration: target.fadeOutDuration, applyMix: false, rawTarget: restoredVol)
                        logger.debug("Unducking '\(target.channel)' to \(restoredVol) (trigger: \(trigger))")
                    }
                    preDuckVolumes.removeValue(forKey: target.channel)
                    duckTriggerCount.removeValue(forKey: target.channel)
                    duckedChannels.remove(target.channel)
                }
            }
        }
    }

    private func clearAllDuckingState() {
        preDuckVolumes.removeAll()
        duckedChannels.removeAll()
        duckTriggerCount.removeAll()
        duckMultipliers.removeAll()
    }

    // MARK: - Helpers

    /// Unified file resolution — the SINGLE method for locating audio files in Media.bundle.
    /// Searches root-level, then subdirectories, then Bundle.main as fallback.
    /// `internal` access enables `@testable import` verification in unit tests.
    ///
    /// Tries alternate **extension casing** (e.g. catalog `.wav` vs on-disk `.WAV`) because
    /// `Bundle.url(forResource:withExtension:)` is case-sensitive on some filesystems/devices.
    /// Optional injected resolver. Consulted ahead of the bundle search so a
    /// downloaded asset pack or a `.chapterscript` folder loaded from disk can
    /// shadow built-in assets without requiring a rebuild.
    public var mediaResolver: MediaResolver?

    public func resolveAudioFile(_ file: String) -> URL? {
        // Consult the injected resolver first. The asset id may be a logical
        // name (e.g. "narration/intro-vo") or a filename — the resolver decides.
        if let resolved = mediaResolver?.url(for: file, kind: .audio) {
            return resolved
        }

        if let direct = resolveAudioFileDirect(file) {
            return direct
        }

        if let fallback = Self.audioFileFallbacks[file],
           let fallbackURL = resolveAudioFileDirect(fallback) {
            logger.warning("Audio fallback applied: \(file, privacy: .public) -> \(fallback, privacy: .public)")
            return fallbackURL
        }

        return nil
    }

    private func resolveAudioFileDirect(_ file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension

        guard let bundlePath = Bundle.main.path(forResource: "Media", ofType: "bundle"),
              let mediaBundle = Bundle(path: bundlePath) else { return nil }

        let extVariants = Self.pathExtensionLookupVariants(ext)

        for tryExt in extVariants {
            if let url = mediaBundle.url(forResource: name, withExtension: tryExt) {
                return url
            }
            for subdir in ["audio/ambient", "audio/sfx", "audio/narration", "audio/scene_audio", "audio/spatial"] {
                if let url = mediaBundle.url(forResource: name, withExtension: tryExt, subdirectory: subdir) {
                    return url
                }
            }
            if let url = Bundle.main.url(forResource: name, withExtension: tryExt) {
                return url
            }
        }

        return nil
    }

    /// `.wav` / `.WAV` (and same for mp3/m4a) so catalog strings match shipped bundle files.
    private static func pathExtensionLookupVariants(_ ext: String) -> [String] {
        guard !ext.isEmpty else { return [""] }
        var out: [String] = []
        for candidate in [ext, ext.lowercased(), ext.uppercased()] {
            if !out.contains(candidate) {
                out.append(candidate)
            }
        }
        return out
    }

    private func findAudioURL(file: String) -> URL? {
        // Cache hit for preloaded catalog files
        if let cached = resolvedURLs[file] {
            return cached
        }
        // Live fallback for non-catalog files (zone audio, runtime variations)
        return resolveAudioFile(file)
    }

    private func volumeToDecibels(_ volume: Float) -> Float {
        if volume <= 0.001 { return -80.0 }
        return 20.0 * log10(volume)
    }

    // MARK: - Mixer Debug API

    public struct ChannelInfo: Sendable {
        public let channel: String
        public let file: String
        public let category: String
        public let busId: String
        public let targetVolume: Float
        public let effectiveVolume: Float
        public let isDucked: Bool
        public let duckMultiplier: Float
        public let isLooping: Bool
        public let loopPhase: String          // "one-shot", "intro", "looping", "outro"
        public let spatialInfo: String?       // position or entity name, nil for ambient
    }

    public struct BusState: Sendable {
        public let id: String
        public let volume: Float
        public let effects: [String]
        public let channelCount: Int
    }

    public struct ZoneSummary: Sendable {
        public let id: String
        public let isActive: Bool
        public let listenerDistance: Float
    }

    public func allActiveChannelNames() -> [String] {
        let ambient = ambientChannels.keys
        let spatial = spatialChannels.keys
        return (Array(ambient) + Array(spatial)).sorted()
    }

    public func channelInfo(_ channel: String) -> ChannelInfo? {
        let cat = categoryForChannel(channel)
        let bus = busForChannel(channel)
        let duckMul = duckMultipliers[channel] ?? 1.0
        let isDucked = duckedChannels.contains(channel)

        if let ch = ambientChannels[channel] {
            let eff = effectiveVolume(requested: ch.targetVolume, channel: channel)
            let loopPhaseStr: String
            if let ls = loopStates[channel] {
                switch ls.phase {
                case .playingIntro: loopPhaseStr = "intro"
                case .looping: loopPhaseStr = "looping"
                case .playingOutro: loopPhaseStr = "outro"
                case .stopped: loopPhaseStr = "stopped"
                }
            } else {
                loopPhaseStr = ch.isLooping ? "looping" : "one-shot"
            }
            return ChannelInfo(
                channel: channel, file: ch.file, category: cat, busId: bus,
                targetVolume: ch.targetVolume, effectiveVolume: eff,
                isDucked: isDucked, duckMultiplier: duckMul,
                isLooping: ch.isLooping, loopPhase: loopPhaseStr,
                spatialInfo: nil
            )
        }

        if let ch = spatialChannels[channel] {
            let eff = effectiveVolume(requested: ch.targetVolume, channel: channel)
            let spatial: String
            if let parent = ch.entity.parent, parent !== audioRoot {
                spatial = "entity: \(parent.name)"
            } else {
                let p = ch.entity.position
                spatial = String(format: "(%.1f, %.1f, %.1f)", p.x, p.y, p.z)
            }
            return ChannelInfo(
                channel: channel, file: ch.file, category: cat, busId: bus,
                targetVolume: ch.targetVolume, effectiveVolume: eff,
                isDucked: isDucked, duckMultiplier: duckMul,
                isLooping: false, loopPhase: "one-shot",
                spatialInfo: spatial
            )
        }

        return nil
    }

    public func allBusStates() -> [BusState] {
        buses.values.map { bus in
            let count = ambientChannels.values.filter { $0.busId == bus.id }.count
            let effectDescs = bus.effects.map { effect -> String in
                switch effect {
                case .reverb(let mix): return "Reverb (\(Int(mix * 100))%)"
                case .compressor(let t, let r): return "Comp (T:\(Int(t))dB R:\(String(format: "%.1f", r)):1)"
                }
            }
            return BusState(id: bus.id, volume: bus.volume, effects: effectDescs, channelCount: count)
        }.sorted { $0.id < $1.id }
    }

    public func activeZoneSummaries() -> [ZoneSummary] {
        zones.map { (id, zone) in
            let distance = simd_distance(listenerPosition, zone.center)
            let isActive = activeZoneChannels[id] != nil
            return ZoneSummary(id: id, isActive: isActive, listenerDistance: distance)
        }.sorted { $0.id < $1.id }
    }

    public func setChannelVolume(_ channel: String, volume: Float) {
        let clamped = max(0, min(1, volume))
        if var ch = ambientChannels[channel] {
            ch.targetVolume = clamped
            ambientChannels[channel] = ch
            let eff = effectiveVolume(requested: clamped, channel: channel)
            ch.playerNode.volume = eff
        }
        if var ch = spatialChannels[channel] {
            ch.targetVolume = clamped
            spatialChannels[channel] = ch
            let eff = effectiveVolume(requested: clamped, channel: channel)
            ch.controller?.gain = Audio.Decibel(volumeToDecibels(eff))
        }
    }

    private var preSoloVolumes: [String: Float]?

    public func soloChannel(_ channel: String) {
        var saved: [String: Float] = [:]
        for (name, ch) in ambientChannels {
            saved[name] = ch.targetVolume
            if name != channel { setChannelVolume(name, volume: 0) }
        }
        for (name, ch) in spatialChannels {
            saved[name] = ch.targetVolume
            if name != channel { setChannelVolume(name, volume: 0) }
        }
        preSoloVolumes = saved
    }

    public func unsoloAll() {
        guard let saved = preSoloVolumes else { return }
        for (name, vol) in saved {
            setChannelVolume(name, volume: vol)
        }
        preSoloVolumes = nil
    }

    public var isSoloing: Bool { preSoloVolumes != nil }

    private var preMuteVolume: Float?

    public var isMuted: Bool {
        get { preMuteVolume != nil }
        set {
            if newValue && preMuteVolume == nil {
                preMuteVolume = mixState.masterVolume
                mixState.masterVolume = 0
            } else if !newValue, let saved = preMuteVolume {
                mixState.masterVolume = saved
                preMuteVolume = nil
            }
        }
    }
}
