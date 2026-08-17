//
//  StepAction.swift
//  SharedVisions
//
//  Composable actions that fire when a step starts.
//  Multiple actions execute in parallel within a single step.
//

import Foundation
import simd
import SwiftUI
import ChapterScript

// MARK: - Step Action

public enum StepAction: Sendable {
    // Entity
    case showEntity(name: String)
    case hideEntity(name: String)
    case moveEntity(MoveAction)
    case scaleEntity(name: String, multiplier: Float, duration: TimeInterval, timing: StepTimingFunction)
    case fadeEntity(FadeAction)
    case persistEntity(name: String)
    case unpersistEntity(name: String)
    case revealEntity(RevealAction)
    case animateMotion(AnimateMotionAction)
    /// Motion Actions 2.0. Carried verbatim — the DTO is the authored truth
    /// and `MotionBehaviorResolver` is the only thing that turns it into
    /// numbers, on device exactly as in the editor.
    case motionBehavior(ChapterScript.MotionBehaviorDTO)

    // Attachments (SwiftUI in 3D)
    case showAttachment(id: String)
    case hideAttachment(id: String)
    case fadeAttachment(id: String, opacity: Float, duration: TimeInterval)
    case setAttachmentView(id: String, viewId: String)
    /// Attachment positioning (headYOnly — mirrors .moveEntity pattern for attachment entities).
    case positionAttachment(id: String, headRelativePosition: SIMD3<Float>, headYOnly: Bool)

    // Audio
    case playAudio(AudioAction)
    case stopAudio(channel: String)
    case fadeAudio(channel: String, to: Float, duration: TimeInterval)

    // Video
    case playVideo(VideoAction)
    case prepareVideo(VideoAction)
    case stopVideo(channel: String)

    // Effects — narrow surface for SharedVisions. Effect authors plug additional cases here.
    case showPulseRing(PulseRingConfig)
    case hidePulseRing
    case startSparkBurst(SparkBurstConfig)
    case stopSparkBurst

    // Audio Mix
    case setMasterVolume(Float)
    case setCategoryVolume(category: String, volume: Float)

    // Audio Completion — runs `then` actions after `channel` finishes.
    case onAudioComplete(channel: String, then: [StepAction])

    // Audio Zones
    case addAudioZone(AudioZone)
    case removeAudioZone(id: String)
    case removeAllAudioZones

    // Audio Bus
    case setBusVolume(busId: String, volume: Float)
    case setBusEffect(busId: String, effect: AudioEffect)
    case removeBusEffect(busId: String, effect: AudioEffect)

    // Gesture control
    case enableGesture(entity: String)
    case disableGesture(entity: String)

    // Interaction control — arm or disarm one authored `InteractionSpec` on an
    // entity. See `InteractionController`.
    case enableInteraction(entity: String, interactionId: String)

    /// WHERE THE STORY GOES NEXT. Carried verbatim from the authored action;
    /// the executor hands it to `ExperienceNavigator` and does nothing else,
    /// so an Interaction's Go To and a Sequence's completion converge on the
    /// same authority.
    case navigate(NavigationIntent)

    /// WHAT THE STORY REMEMBERS. Carried verbatim; the engine hands it to the
    /// session's `StoryStateStore` and the arithmetic is the shared one in
    /// `ChapterScript.StoryStateArithmetic`, so a Mac preview and a headset
    /// cannot end the same tap holding different values.
    case setStoryState(StoryStateMutation)

    case disableInteraction(entity: String, interactionId: String)

    // Upper limb and keyboard passthrough (visionOS system UI)
    case setUpperLimbVisibility(_ visibility: Visibility)
    case setKeyboardPassthrough(_ enabled: Bool)

    // Custom escape hatch
    case custom(id: String)

    /// True only for actions whose executor method is async.
    /// All other actions execute synchronously and must not be `await`ed
    /// to avoid MainActor suspension points that starve the step loop.
    public var isAsync: Bool {
        switch self {
        case .custom:
            // Extend here if specific custom ids are async; default to sync.
            return false
        default:
            return false
        }
    }
}

// MARK: - Move Action

public struct MoveAction: Sendable {
    public let entity: String
    public let positionOffset: SIMD3<Float>?
    public let absolutePosition: SIMD3<Float>?
    public let headRelativePosition: SIMD3<Float>?
    /// When true, only the head's world Y is sampled.
    /// X and Z in `headRelativePosition` are treated as world-space coordinates.
    /// Result: world position = (specifiedX, headWorldY + specifiedY, specifiedZ).
    public let headYOnly: Bool
    public let scaleMultiplier: Float?
    public let absoluteScale: SIMD3<Float>?
    /// Final absolute orientation. When set, the entity animates to this
    /// orientation over `duration`.
    public let absoluteRotation: simd_quatf?
    /// Relative orientation delta composed onto the entity's current
    /// orientation. Ignored when `absoluteRotation` is set.
    public let rotationOffset: simd_quatf?
    public let duration: TimeInterval
    public let timing: StepTimingFunction

    public init(
        entity: String,
        positionOffset: SIMD3<Float>? = nil,
        absolutePosition: SIMD3<Float>? = nil,
        headRelativePosition: SIMD3<Float>? = nil,
        headYOnly: Bool = false,
        scaleMultiplier: Float? = nil,
        absoluteScale: SIMD3<Float>? = nil,
        absoluteRotation: simd_quatf? = nil,
        rotationOffset: simd_quatf? = nil,
        duration: TimeInterval = 1.0,
        timing: StepTimingFunction = .easeInOut
    ) {
        assert(headRelativePosition == nil || absolutePosition == nil,
               "headRelativePosition and absolutePosition are mutually exclusive")
        assert(!headYOnly || headRelativePosition != nil,
               "headYOnly requires headRelativePosition to be set")
        self.entity = entity
        self.positionOffset = positionOffset
        self.absolutePosition = absolutePosition
        self.headRelativePosition = headRelativePosition
        self.headYOnly = headYOnly
        self.scaleMultiplier = scaleMultiplier
        self.absoluteScale = absoluteScale
        self.absoluteRotation = absoluteRotation
        self.rotationOffset = rotationOffset
        self.duration = duration
        self.timing = timing
    }
}

// MARK: - Fade Action

/// A step action that animates an entity's opacity via `OpacityComponent`.
///
/// **Important:** `fadeEntity` makes the entity visually transparent but it remains
/// enabled — it still receives gestures and participates in collisions.
/// Use `hideEntity` to fully remove an entity from the render graph.
public struct FadeAction: Sendable {
    public let entity: String
    /// Target opacity, clamped to 0.0–1.0.
    public let opacity: Float
    /// Animation duration, clamped ≥ 0. Duration of 0 snaps immediately.
    public let duration: TimeInterval
    public let timing: StepTimingFunction

    public init(
        entity: String,
        opacity: Float,
        duration: TimeInterval = 1.0,
        timing: StepTimingFunction = .easeInOut
    ) {
        self.entity = entity
        self.opacity = min(max(opacity, 0.0), 1.0)
        self.duration = max(duration, 0)
        self.timing = timing
    }
}

// MARK: - Animate Motion Action

/// Per-frame parametric/keyframe motion driven by `MotionCurve`. The action describes
/// optional position/scale/rotation curves; the engine evaluates them every frame
/// against `engine.stepElapsed / duration` and `engine.totalElapsed`. Motions clear
/// at the next step boundary.
///
/// Curves come straight from the ChapterScript format; no runtime mirror needed
/// because they're all primitive Codable value types.
public struct AnimateMotionAction: Sendable {
    public let entity: String
    public let position: ChapterScript.MotionCurve?
    public let scale: ChapterScript.MotionCurve?
    public let rotation: ChapterScript.MotionCurve?
    public let duration: TimeInterval
}

// MARK: - Reveal Action

/// Atomically snap-invisible → position/scale → enable → fade-in an entity.
/// Eliminates the fragile multi-step show/fade choreography that causes visual pops.
/// `revealEntity` MUST be the first action in its step's action array.
public struct RevealAction: Sendable {
    public let entity: String
    public let position: SIMD3<Float>?
    public let headRelativePosition: SIMD3<Float>?
    public let headYOnly: Bool
    public let scale: SIMD3<Float>?
    public let fadeIn: TimeInterval
    /// When true, the revealed entity is made directly hand-manipulable
    /// (RealityKit ManipulationComponent — grab / move / rotate / scale).
    public let manipulable: Bool

    public init(
        entity: String,
        position: SIMD3<Float>? = nil,
        headRelativePosition: SIMD3<Float>? = nil,
        headYOnly: Bool = false,
        scale: SIMD3<Float>? = nil,
        fadeIn: TimeInterval = 0,
        manipulable: Bool = false
    ) {
        assert(headRelativePosition == nil || position == nil,
               "headRelativePosition and position are mutually exclusive")
        assert(!headYOnly || headRelativePosition != nil,
               "headYOnly requires headRelativePosition to be set")
        self.entity = entity
        self.position = position
        self.headRelativePosition = headRelativePosition
        self.headYOnly = headYOnly
        self.scale = scale
        self.fadeIn = max(fadeIn, 0)
        self.manipulable = manipulable
    }
}

// MARK: - Audio Scope

/// Determines audio lifecycle during sequence transitions.
/// - `.sequence`: killed automatically on sequence change (default).
/// - `.ambient`: persists across sequence changes until explicitly stopped.
public enum AudioScope: Sendable {
    case sequence
    case ambient
}

// MARK: - Audio Action

public struct AudioAction: Sendable {
    public let file: String
    public let channel: String
    public let scope: AudioScope
    public let volume: Float
    public let loop: Bool
    public let fadeIn: TimeInterval?
    public let spatial: SpatialAudioConfig?
    public let category: String?
    public let crossfade: TimeInterval?
    public let loopConfig: LoopConfig?
    /// Non-destructive source window into the master file, in master-file
    /// seconds. `.full` (the default) plays the whole file, which is what
    /// every document written before audio had marks means.
    ///
    /// Looping loops the WINDOW, not the file. See `MediaSourceRange`.
    public let sourceRange: MediaSourceRange

    /// THE AUTHORED PLAYBACK SEMANTICS, carried through from the document.
    ///
    /// This field used to be dropped by the DTO bridge, so the runtime decided
    /// semantics from `spatial != nil` — a boolean that answers "is there
    /// attachment metadata", not "how should this be played". Head-locked
    /// stereo, an ambisonic bed and an Apple Spatial Audio master all took one
    /// path as a result.
    ///
    /// `nil` means a document written before the field existed;
    /// `AudioRuntimeRouting` applies the historic inference for those, so no
    /// existing chapter changes how it sounds.
    public let playbackModel: AudioPlaybackModel?

    /// The listening frame for an encoded spatial master — head-tracked or
    /// fixed. A rendering concept, not a transform; meaningful only for
    /// `.spatialMix`.
    public let spatialPresentation: AudioSpatialPresentation?

    public init(
        file: String,
        channel: String,
        scope: AudioScope = .sequence,
        volume: Float = 1.0,
        loop: Bool = false,
        fadeIn: TimeInterval? = nil,
        spatial: SpatialAudioConfig? = nil,
        category: String? = nil,
        crossfade: TimeInterval? = nil,
        loopConfig: LoopConfig? = nil,
        sourceRange: MediaSourceRange = .full,
        playbackModel: AudioPlaybackModel? = nil,
        spatialPresentation: AudioSpatialPresentation? = nil
    ) {
        self.file = file
        self.channel = channel
        self.scope = scope
        self.volume = volume
        self.loop = loop
        self.fadeIn = fadeIn
        self.spatial = spatial
        self.category = category
        self.crossfade = crossfade
        self.loopConfig = loopConfig
        self.sourceRange = sourceRange
        self.playbackModel = playbackModel
        self.spatialPresentation = spatialPresentation
    }

    /// Where this cue should play, and whether that honours the authored
    /// intent. One decision, shared with the editor — see
    /// `ChapterScript.AudioRuntimeRouting`.
    public var routing: AudioRuntimeRouting.Support {
        AudioRuntimeRouting.route(
            playbackModel: playbackModel,
            hasSpatialAttachment: spatial?.attachToEntity != nil || spatial?.position != nil
        )
    }
}

// MARK: - Loop Config

public struct LoopConfig: Sendable {
    public let intro: String?
    public let loop: String
    public let outro: String?
    public let crossfade: TimeInterval

    public init(intro: String? = nil, loop: String, outro: String? = nil, crossfade: TimeInterval = 1.0) {
        self.intro = intro
        self.loop = loop
        self.outro = outro
        self.crossfade = crossfade
    }
}

// MARK: - Sound Variation

public struct SoundVariation: Sendable {
    public let pool: [String]
    public let mode: SelectionMode

    public init(pool: [String], mode: SelectionMode = .shuffle) {
        self.pool = pool
        self.mode = mode
    }
}

public enum SelectionMode: String, Sendable {
    case random
    case sequential
    case shuffle
}

public struct SpatialAudioConfig: Sendable {
    public let position: SIMD3<Float>?
    public let attachToEntity: String?

    public init(position: SIMD3<Float>? = nil, attachToEntity: String? = nil) {
        self.position = position
        self.attachToEntity = attachToEntity
    }
}

// MARK: - Video Action

public struct VideoAction: Sendable {
    public let file: String
    public let channel: String
    public let volume: Float
    public let loop: Bool
    public let presentation: VideoPresentation
    public let layout: VideoLayout
    /// Non-destructive source trim: playback starts this many seconds into
    /// the master file. `nil` plays from the start. The file's bytes are
    /// untouched — the trim is pure action metadata from the editor.
    public let sourceIn: Double?
    /// Exclusive end of the source window (master-file seconds). `nil`
    /// plays to the natural end. Looping loops `[sourceIn, sourceOut)`.
    public let sourceOut: Double?

    public init(
        file: String,
        channel: String,
        volume: Float = 1.0,
        loop: Bool = false,
        presentation: VideoPresentation = .attachment(id: "video"),
        layout: VideoLayout = .mono,
        sourceIn: Double? = nil,
        sourceOut: Double? = nil
    ) {
        self.file = file
        self.channel = channel
        self.volume = volume
        self.loop = loop
        self.presentation = presentation
        self.layout = layout
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
    }
}

public enum VideoPresentation: Sendable {
    case attachment(id: String)
    case entity(name: String, width: Float, height: Float)
    /// Immersive 360°/180° on a sphere of `radius` meters around the user.
    case immersive(radius: Float, field: ImmersiveField)
}

/// Runtime mirror of `ChapterScript.ImmersiveField`.
///
/// Carries degrees for the same reason the DTO does: Apple Immersive Video is
/// NOT 180° — Apple's parametric projection reaches past the ±90° plane, so a
/// hemisphere clips real picture at both edges. `horizontalDegrees` is the one
/// place a field becomes an angle; build shells from it, never from a
/// hard-coded π.
public enum ImmersiveField: Sendable, Equatable, Hashable {
    case equirect360
    case equirect180
    case appleImmersive(degrees: Float)
    case custom(degrees: Float)

    public var horizontalDegrees: Float {
        switch self {
        case .equirect360: return 360
        case .equirect180: return 180
        case .appleImmersive(let degrees), .custom(let degrees):
            return min(max(degrees, 1), 360)
        }
    }

    /// Apple's parametric projection rather than a plain equirectangular map.
    public var isAppleParametric: Bool {
        if case .appleImmersive = self { return true }
        return false
    }
}

/// How a video file packs its eye(s) on disk.
/// `.mono` — flat 2D, single eye.
/// `.sideBySide` / `.overUnder` — frame-packed stereo, player splits manually.
/// `.multiviewHEVC` — Apple spatial video; AVPlayer auto-decodes per-eye.
public enum VideoLayout: String, Sendable {
    case mono, sideBySide, overUnder, multiviewHEVC
}

// MARK: - Scheduled Action

public struct ScheduledAction: Sendable {
    public let at: TimeInterval        // Seconds after step starts (0.0 = immediate)
    public let action: StepAction
}

// MARK: - Audio Zone

public struct AudioZone: Sendable {
    public let id: String
    public let center: SIMD3<Float>
    public let radius: Float              // Activation radius in meters
    public let falloffStart: Float        // Start fading at this distance (< radius)
    public let audio: AudioAction         // What to play when in zone
    public let fadeInDuration: TimeInterval
    public let fadeOutDuration: TimeInterval

    public init(
        id: String,
        center: SIMD3<Float>,
        radius: Float,
        falloffStart: Float? = nil,
        audio: AudioAction,
        fadeInDuration: TimeInterval = 1.0,
        fadeOutDuration: TimeInterval = 1.0
    ) {
        self.id = id
        self.center = center
        self.radius = radius
        self.falloffStart = falloffStart ?? (radius * 0.5)
        self.audio = audio
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }
}

// MARK: - Audio Effect

public enum AudioEffect: Sendable, Equatable {
    case reverb(wetDryMix: Float)
    case compressor(threshold: Float, ratio: Float)
}

// MARK: - Audio Bus

public struct AudioBus: Sendable {
    public let id: String
    public var volume: Float
    public var effects: [AudioEffect]

    public init(id: String, volume: Float = 1.0, effects: [AudioEffect] = []) {
        self.id = id
        self.volume = volume
        self.effects = effects
    }
}

// MARK: - Audio Ducking

public struct DuckingRule: Sendable {
    public let trigger: String          // Channel that triggers ducking (e.g. "narration")
    public let targets: [DuckTarget]    // Channels to duck
}

public struct DuckTarget: Sendable {
    public let channel: String          // Channel to duck (e.g. "ambient", "sequence_audio")
    public let duckLevel: Float         // Volume multiplier when ducked (0.2 = duck to 20% of current volume)
    public let fadeInDuration: TimeInterval   // How fast to duck down
    public let fadeOutDuration: TimeInterval  // How fast to restore
}

// MARK: - Pulse Ring Config (example VFX #1)

/// Configuration for `showPulseRing` — a ring of emissive discs arranged around the user,
/// pulsing in brightness on a sine wave. Archetype: ambient, persistent, spatial.
public struct PulseRingConfig: Sendable, Equatable {
    /// Ring radius in meters. Default ~1.5m places the ring just out of arm's reach.
    public var radius: Float = 1.5
    /// Height above world origin where the ring sits.
    public var height: Float = 1.2
    /// Number of discs around the ring.
    public var ringCount: Int = 24
    /// Base emissive strength for each disc.
    public var baseIntensity: Float = 0.4
    /// Peak emissive strength at pulse crest.
    public var peakIntensity: Float = 1.6
    /// Pulse frequency in Hz (full cycles per second).
    public var pulseSpeed: Float = 0.5
    /// Per-disc mesh radius in meters (small torus-like disc).
    public var discRadius: Float = 0.04
    /// Color of the rings (stored as RGBA components for Sendable Equatable).
    public var colorRed: Float = 0.3
    public var colorGreen: Float = 0.85
    public var colorBlue: Float = 1.0

    public init(
        radius: Float = 1.5,
        height: Float = 1.2,
        ringCount: Int = 24,
        baseIntensity: Float = 0.4,
        peakIntensity: Float = 1.6,
        pulseSpeed: Float = 0.5,
        discRadius: Float = 0.04,
        colorRed: Float = 0.3,
        colorGreen: Float = 0.85,
        colorBlue: Float = 1.0
    ) {
        self.radius = radius
        self.height = height
        self.ringCount = ringCount
        self.baseIntensity = baseIntensity
        self.peakIntensity = peakIntensity
        self.pulseSpeed = pulseSpeed
        self.discRadius = discRadius
        self.colorRed = colorRed
        self.colorGreen = colorGreen
        self.colorBlue = colorBlue
    }
}

// MARK: - Spark Burst Config (example VFX #2)

/// Configuration for `startSparkBurst` — a one-shot upward firework burst from a point.
/// Archetype: ephemeral, directional, eye-catching accent.
public struct SparkBurstConfig: Sendable, Equatable {
    /// World position of the burst origin.
    public var position: SIMD3<Float> = [0, 1.0, -1.5]
    /// Sphere emitter radius (meters).
    public var burstRadius: Float = 0.5
    /// Initial particle spawn rate.
    public var particleBirthRate: Float = 300
    /// Particle lifetime in seconds.
    public var particleLifeSpan: Float = 1.2
    /// Total burst duration before emission stops.
    public var duration: TimeInterval = 2.0
    /// Individual particle size in meters.
    public var particleSize: Float = 0.02
    /// Tint color (RGBA components).
    public var tintRed: Float = 1.0
    public var tintGreen: Float = 0.7
    public var tintBlue: Float = 0.2

    public init(
        position: SIMD3<Float> = [0, 1.0, -1.5],
        burstRadius: Float = 0.5,
        particleBirthRate: Float = 300,
        particleLifeSpan: Float = 1.2,
        duration: TimeInterval = 2.0,
        particleSize: Float = 0.02,
        tintRed: Float = 1.0,
        tintGreen: Float = 0.7,
        tintBlue: Float = 0.2
    ) {
        self.position = position
        self.burstRadius = burstRadius
        self.particleBirthRate = particleBirthRate
        self.particleLifeSpan = particleLifeSpan
        self.duration = duration
        self.particleSize = particleSize
        self.tintRed = tintRed
        self.tintGreen = tintGreen
        self.tintBlue = tintBlue
    }
}
