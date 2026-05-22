//
//  AudioActionExecutor.swift
//  SharedVisions
//
//  Bridges StepAction audio commands to SpatialAudioManager.
//

import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "AudioActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol AudioActionExecutorProtocol {
    func play(_ action: AudioAction, stepContext: String?)
    func stop(channel: String)
    func fade(channel: String, to: Float, duration: TimeInterval)
    func pauseAll()
    func resumeAll()
    func stopAll()
    func stopEverything()
    var currentMasterVolume: Float { get }
    var activeZoneCount: Int { get }
    func setMasterVolume(_ volume: Float)
    func setCategoryVolume(category: String, volume: Float)
    var onChannelFinished: ((String) -> Void)? { get set }
    // Audio Zones
    func addAudioZone(_ zone: AudioZone)
    func removeAudioZone(id: String)
    func removeAllAudioZones()
    // Audio Bus
    func setBusVolume(busId: String, volume: Float)
    func setBusEffect(busId: String, effect: AudioEffect)
    func removeBusEffect(busId: String, effect: AudioEffect)
}

// MARK: - Implementation

@MainActor
public final class AudioActionExecutor: AudioActionExecutorProtocol {

    /// Shared ducking targets for all narration channels.
    static public let narrationDuckTargets: [DuckTarget] = [
        DuckTarget(channel: "ambient", duckLevel: 0.2, fadeInDuration: 0.8, fadeOutDuration: 1.5),
        DuckTarget(channel: "ambient_main", duckLevel: 0.2, fadeInDuration: 0.8, fadeOutDuration: 1.5),
        DuckTarget(channel: "chapter_audio", duckLevel: 0.4, fadeInDuration: 0.8, fadeOutDuration: 1.5),
        DuckTarget(channel: "sfx", duckLevel: 0.6, fadeInDuration: 0.5, fadeOutDuration: 0.8),
    ]

    public let audioManager: SpatialAudioManager

    /// Channels that survive chapter transitions — dynamically populated
    /// when audio is played with `scope: .ambient`.
    public var protectedChannels: Set<String> = []

    /// Completion callback — wired by ChapterEngine for .onAudioComplete actions
    public var onChannelFinished: ((String) -> Void)? {
        get { self.audioManager.onChannelFinished }
        set { self.audioManager.onChannelFinished = newValue }
    }

    public init(audioManager: SpatialAudioManager) {
        self.audioManager = audioManager

        // Clean up protectedChannels when a channel is removed
        // (fade-to-zero, loop outro, explicit stop).
        audioManager.onChannelStopped = { [weak self] channel in
            self?.protectedChannels.remove(channel)
        }
    }

    public func play(_ action: AudioAction, stepContext: String?) {
        if action.scope == .ambient {
            protectedChannels.insert(action.channel)
        }
        audioManager.play(action: action, stepContext: stepContext)
    }

    public func stop(channel: String) {
        protectedChannels.remove(channel)
        audioManager.stop(channel: channel)
    }

    public func fade(channel: String, to volume: Float, duration: TimeInterval) {
        audioManager.fade(channel: channel, to: volume, duration: duration)
    }

    public func configureDucking(rules: [DuckingRule]) {
        audioManager.duckingRules = rules
        logger.info("Configured \(rules.count) ducking rule(s)")
    }

    // MARK: - Mix Controls

    public func setMasterVolume(_ volume: Float) {
        audioManager.mixState.masterVolume = max(0, min(1, volume))
        logger.info("Master volume → \(self.audioManager.mixState.masterVolume)")
    }

    public func setCategoryVolume(category: String, volume: Float) {
        audioManager.mixState.categoryVolumes[category] = max(0, min(1, volume))
        logger.info("Category '\(category)' volume → \(volume)")
    }

    /// Set category volume using decibels. 0 dB = unchanged, -6 dB ≈ half, -80 dB = mute.
    public func setCategoryVolumeDB(category: String, dB: Float) {
        let linear: Float = dB <= -80 ? 0 : pow(10, dB / 20.0)
        setCategoryVolume(category: category, volume: linear)
        logger.info("Category '\(category)' volume → \(dB) dB (linear: \(linear))")
    }

    public func pauseAll() {
        audioManager.pauseAll()
    }

    public func resumeAll() {
        audioManager.resumeAll()
    }

    public var currentMasterVolume: Float {
        audioManager.mixState.masterVolume
    }

    public var activeZoneCount: Int {
        audioManager.activeZoneCount
    }

    /// Stops all chapter audio — preserves protected ambient channels.
    public func stopAll() {
        audioManager.stopAll(except: protectedChannels)
    }

    /// Stops everything including ambient. Called on full shutdown.
    public func stopEverything() {
        audioManager.stopEverything()
        protectedChannels.removeAll()
    }

    // MARK: - Audio Zones

    public func addAudioZone(_ zone: AudioZone) {
        audioManager.addAudioZone(zone)
    }

    public func removeAudioZone(id: String) {
        audioManager.removeAudioZone(id: id)
    }

    public func removeAllAudioZones() {
        audioManager.removeAllAudioZones()
    }

    // MARK: - Audio Bus

    public func setBusVolume(busId: String, volume: Float) {
        audioManager.setBusVolume(busId, volume: max(0, min(1, volume)))
    }

    public func setBusEffect(busId: String, effect: AudioEffect) {
        audioManager.setBusEffect(busId: busId, effect: effect)
    }

    public func removeBusEffect(busId: String, effect: AudioEffect) {
        audioManager.removeBusEffect(busId: busId, effect: effect)
    }
}
