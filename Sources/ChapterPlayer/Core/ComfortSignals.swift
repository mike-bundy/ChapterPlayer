//
//  ComfortSignals.swift
//  ChapterPlayer
//
//  WHAT THE SYSTEM IS TELLING US ABOUT COMFORT AND HEAT, SURFACED.
//
//  Two signals the platform already sends and this runtime used to drop:
//
//    1. `VideoPlayerEvents.VideoComfortMitigationDidOccur` — a RealityKit
//       scene EVENT (visionOS 26+, not a notification), raised when the system
//       intervenes in immersive video for the viewer's comfort. It carries a
//       `VideoPlayerComponent.VideoComfortMitigation`: `.play`, `.pause` or
//       `.reduceImmersion`.
//    2. `ProcessInfo.thermalStateDidChangeNotification`.
//
//  SURFACING IS THE WHOLE SCOPE. Nothing here changes playback quality, pauses
//  a Sequence or sheds work — a response policy is a product decision that has
//  to be made wearing a headset, and a runtime that quietly degrades on its
//  own is a bug report nobody can reproduce. This publishes the latest facts
//  and logs every change, so a host can show them and a device session can
//  read them back out of the log.
//
//  The recording half is pure (`recordThermal`, `recordMitigation` take their
//  inputs as values), so it is tested without a scene and without heating a
//  device. Only `startObservingThermalState` and `observeVideoComfort(in:)`
//  touch the system.
//

import Combine
import Foundation
import OSLog
import RealityKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "ComfortSignals"
)

@MainActor
@Observable
public final class ComfortSignals {

    // MARK: - Values

    /// `ProcessInfo.ThermalState`, as a value this package owns: ordered, so
    /// "did it get worse" is a comparison, and `CaseIterable` for a host menu.
    public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal:  self = .nominal
            case .fair:     self = .fair
            case .serious:  self = .serious
            case .critical: self = .critical
            // A state a future OS adds is, by the platform's own ordering,
            // beyond critical. Reading it as nominal would hide the one
            // reading that matters most.
            @unknown default: self = .critical
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The platform's own word for it, for a host label or a log line.
        public var label: String {
            switch self {
            case .nominal:  return "Nominal"
            case .fair:     return "Fair"
            case .serious:  return "Serious"
            case .critical: return "Critical"
            }
        }

        /// Serious or worse: the system is already throttling.
        public var isConstrained: Bool { self >= .serious }
    }

    /// What the system did to immersive video for the viewer's comfort.
    public enum VideoMitigation: String, Sendable, Equatable, CaseIterable {
        case play
        case pause
        case reduceImmersion
        /// A mitigation a newer OS reports that this build has no name for.
        /// Counted and logged, never dropped.
        case unknown

        public var label: String {
            switch self {
            case .play:            return "Resumed playback"
            case .pause:           return "Paused playback"
            case .reduceImmersion: return "Reduced immersion"
            case .unknown:         return "Unrecognized mitigation"
            }
        }
    }

    // MARK: - Published state

    /// The latest thermal reading.
    public private(set) var thermalLevel: ThermalLevel = .nominal
    /// When `thermalLevel` last CHANGED. Nil until it has.
    public private(set) var thermalLevelChangedAt: Date?
    /// The worst reading since observation began or `reset()`.
    public private(set) var peakThermalLevel: ThermalLevel = .nominal

    /// How many comfort mitigations the system has applied this session.
    public private(set) var mitigationCount: Int = 0
    /// The most recent one, and when.
    public private(set) var lastMitigation: VideoMitigation?
    public private(set) var lastMitigationAt: Date?

    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var comfortSubscription: (any Cancellable)?
    @ObservationIgnored private weak var observedScene: RealityKit.Scene?

    public init() {}

    // MARK: - Recording (pure)

    /// Record a thermal reading. Returns true when the level CHANGED, which
    /// is the only time anything is published or logged — the notification
    /// can repeat a state, and republishing it would invalidate a host view
    /// for a label that reads the same.
    @discardableResult
    public func recordThermal(_ level: ThermalLevel, at date: Date = Date()) -> Bool {
        guard level != thermalLevel else { return false }
        let previous = thermalLevel
        thermalLevel = level
        thermalLevelChangedAt = date
        if level > peakThermalLevel { peakThermalLevel = level }
        if level.isConstrained {
            logger.warning("[comfort] thermal state \(previous.label, privacy: .public) -> \(level.label, privacy: .public)")
        } else {
            logger.info("[comfort] thermal state \(previous.label, privacy: .public) -> \(level.label, privacy: .public)")
        }
        return true
    }

    /// Record one comfort mitigation. Every one counts, including a repeat of
    /// the last: two pauses are two interventions.
    public func recordMitigation(_ mitigation: VideoMitigation, at date: Date = Date()) {
        mitigationCount += 1
        lastMitigation = mitigation
        lastMitigationAt = date
        logger.warning("[comfort] video comfort mitigation #\(self.mitigationCount): \(mitigation.label, privacy: .public)")
    }

    /// Forget the session's history. The current thermal level is a fact about
    /// the device, not the session, so it stays.
    public func reset() {
        mitigationCount = 0
        lastMitigation = nil
        lastMitigationAt = nil
        peakThermalLevel = thermalLevel
    }

    // MARK: - Observation

    /// Begin following the device's thermal state. Idempotent.
    public func startObservingThermalState() {
        guard thermalObserver == nil else { return }
        recordThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
        peakThermalLevel = thermalLevel
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
            }
        }
    }

    /// Follow comfort mitigations raised in `scene`. Idempotent per scene, so
    /// it is safe to call every time a video component is attached.
    public func observeVideoComfort(in scene: RealityKit.Scene?) {
        guard let scene, scene !== observedScene else { return }
        comfortSubscription?.cancel()
        observedScene = scene
        comfortSubscription = scene.subscribe(
            to: VideoPlayerEvents.VideoComfortMitigationDidOccur.self
        ) { [weak self] event in
            let mitigation = VideoMitigation(event.comfortMitigation)
            Task { @MainActor [weak self] in
                self?.recordMitigation(mitigation)
            }
        }
        logger.info("[comfort] observing video comfort mitigations")
    }

    /// Stop observing. NOT in `deinit`: the observer is main-actor isolated
    /// and `deinit` is not. `ChapterPlayerCore` owns one for the app's
    /// lifetime, so in practice this is for hosts that discard a player.
    public func stopObserving() {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
        comfortSubscription?.cancel()
        comfortSubscription = nil
        observedScene = nil
    }
}

extension ComfortSignals.VideoMitigation {
    /// From the SDK's value. `@unknown default` rather than a plain default, so
    /// a case the SDK adds is a compiler warning here, not a silent `.unknown`.
    init(_ mitigation: VideoPlayerComponent.VideoComfortMitigation) {
        switch mitigation {
        case .play:            self = .play
        case .pause:           self = .pause
        case .reduceImmersion: self = .reduceImmersion
        @unknown default:      self = .unknown
        }
    }
}
