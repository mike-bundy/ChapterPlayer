//
//  ChapterScript+Runtime.swift
//  SharedVisions
//
//  Conversions between the open ChapterScript format DTOs and the runtime
//  ChapterEngine types. All mappings are forward-only (DTO → runtime) for now;
//  reverse direction added when an authoring/export pass needs it.
//

import Foundation
import simd
import SwiftUI
import ChapterScript

public enum ChapterScriptRuntimeError: Error, CustomStringConvertible {
    case unsupportedAction(String)
    case unsupportedDocument(reason: String)

    public var description: String {
        switch self {
        case .unsupportedAction(let kind):
            return "ChapterScript action '\(kind)' has no runtime equivalent yet."
        case .unsupportedDocument(let reason):
            return "Unsupported document: \(reason)"
        }
    }
}

// MARK: - Vec3 / Visibility / Timing primitives

extension SIMD3 where Scalar == Float {
    nonisolated init(_ v: ChapterScript.Vec3) { self.init(v.x, v.y, v.z) }
}

extension Visibility {
    nonisolated init(_ kind: ChapterScript.VisibilityKind) {
        switch kind {
        case .automatic: self = .automatic
        case .visible:   self = .visible
        case .hidden:    self = .hidden
        }
    }
}

private extension StepTimingFunction {
    public init(_ dto: ChapterScript.StepTimingFunction) {
        switch dto {
        case .linear:     self = .linear
        case .easeIn:     self = .easeIn
        case .easeOut:    self = .easeOut
        case .easeInOut:  self = .easeInOut
        }
    }
}

private extension AudioScope {
    public init(_ dto: ChapterScript.AudioScope) {
        switch dto {
        case .chapter: self = .chapter
        case .ambient: self = .ambient
        }
    }
}

private extension SelectionMode {
    public init(_ dto: ChapterScript.SelectionMode) {
        switch dto {
        case .random:     self = .random
        case .sequential: self = .sequential
        case .shuffle:    self = .shuffle
        }
    }
}

private extension GateType {
    public init(_ dto: ChapterScript.GateType) {
        switch dto {
        case .tap:          self = .tap
        case .orchestrator: self = .orchestrator
        case .any:          self = .any
        }
    }
}

private extension VideoPresentation {
    public init(_ dto: ChapterScript.VideoPresentation) {
        switch dto {
        case .attachment(let id):
            self = .attachment(id: id)
        case .entity(let name, let width, let height):
            self = .entity(name: name, width: width, height: height)
        case .immersive(let radius, let field):
            self = .immersive(radius: radius, field: ImmersiveField(field))
        }
    }
}

private extension ImmersiveField {
    public init(_ dto: ChapterScript.ImmersiveField) {
        switch dto {
        case .equirect360: self = .equirect360
        case .equirect180: self = .equirect180
        }
    }
}

private extension VideoLayout {
    public init(_ dto: ChapterScript.VideoLayout) {
        switch dto {
        case .mono:           self = .mono
        case .sideBySide:     self = .sideBySide
        case .overUnder:      self = .overUnder
        case .multiviewHEVC:  self = .multiviewHEVC
        }
    }
}

private extension AudioEffect {
    public init(_ dto: ChapterScript.AudioEffectDTO) {
        switch dto {
        case .reverb(let mix):
            self = .reverb(wetDryMix: mix)
        case .compressor(let threshold, let ratio):
            self = .compressor(threshold: threshold, ratio: ratio)
        }
    }
}

// MARK: - MoveAction / FadeAction / RevealAction

private extension MoveAction {
    public init(_ dto: MoveActionDTO) {
        self.init(
            entity: dto.entity,
            positionOffset: dto.positionOffset.map(SIMD3.init),
            absolutePosition: dto.absolutePosition.map(SIMD3.init),
            headRelativePosition: dto.headRelativePosition.map(SIMD3.init),
            headYOnly: dto.headYOnly,
            scaleMultiplier: dto.scaleMultiplier,
            absoluteScale: dto.absoluteScale.map(SIMD3.init),
            duration: dto.duration,
            timing: StepTimingFunction(dto.timing)
        )
    }
}

private extension FadeAction {
    public init(_ dto: FadeActionDTO) {
        self.init(
            entity: dto.entity,
            opacity: dto.opacity,
            duration: dto.duration,
            timing: StepTimingFunction(dto.timing)
        )
    }
}

private extension RevealAction {
    public init(_ dto: RevealActionDTO) {
        self.init(
            entity: dto.entity,
            position: dto.position.map(SIMD3.init),
            headRelativePosition: dto.headRelativePosition.map(SIMD3.init),
            headYOnly: dto.headYOnly,
            scale: dto.scale.map(SIMD3.init),
            fadeIn: dto.fadeIn
        )
    }
}

// MARK: - AudioAction / VideoAction / AudioZone

private extension SpatialAudioConfig {
    public init(_ dto: SpatialAudioConfigDTO) {
        self.init(
            position: dto.position.map(SIMD3.init),
            attachToEntity: dto.attachToEntity
        )
    }
}

private extension LoopConfig {
    public init(_ dto: LoopConfigDTO) {
        self.init(
            intro: dto.intro,
            loop: dto.loop,
            outro: dto.outro,
            crossfade: dto.crossfade
        )
    }
}

private extension AudioAction {
    public init(_ dto: AudioActionDTO) {
        self.init(
            file: dto.file,
            channel: dto.channel,
            scope: AudioScope(dto.scope),
            volume: dto.volume,
            loop: dto.loop,
            fadeIn: dto.fadeIn,
            spatial: dto.spatial.map { SpatialAudioConfig($0) },
            category: dto.category,
            crossfade: dto.crossfade,
            loopConfig: dto.loopConfig.map { LoopConfig($0) }
        )
    }
}

extension VideoAction {
    /// Public DTO bridge used by `AppModel.preheatVideos` to stage AVPlayer
    /// items before chapter playback. Other internal call sites continue
    /// to construct VideoAction directly via this same init.
    public init(_ dto: VideoActionDTO) {
        self.init(
            file: dto.file,
            channel: dto.channel,
            volume: dto.volume,
            loop: dto.loop,
            presentation: VideoPresentation(dto.presentation),
            layout: VideoLayout(dto.layout)
        )
    }
}

private extension AudioZone {
    public init(_ dto: AudioZoneDTO) {
        self.init(
            id: dto.id,
            center: SIMD3(dto.center),
            radius: dto.radius,
            falloffStart: dto.falloffStart,
            audio: AudioAction(dto.audio),
            fadeInDuration: dto.fadeInDuration,
            fadeOutDuration: dto.fadeOutDuration
        )
    }
}

// MARK: - Effect configs

private extension PulseRingConfig {
    public init(_ dto: PulseRingConfigDTO) {
        self.init(
            radius: dto.radius,
            height: dto.height,
            ringCount: dto.ringCount,
            baseIntensity: dto.baseIntensity,
            peakIntensity: dto.peakIntensity,
            pulseSpeed: dto.pulseSpeed,
            discRadius: dto.discRadius,
            colorRed: dto.color.r,
            colorGreen: dto.color.g,
            colorBlue: dto.color.b
        )
    }
}

private extension SparkBurstConfig {
    public init(_ dto: SparkBurstConfigDTO) {
        self.init(
            position: SIMD3(dto.position),
            burstRadius: dto.burstRadius,
            particleBirthRate: dto.particleBirthRate,
            particleLifeSpan: dto.particleLifeSpan,
            duration: dto.duration,
            particleSize: dto.particleSize,
            tintRed: dto.tint.r,
            tintGreen: dto.tint.g,
            tintBlue: dto.tint.b
        )
    }
}

// MARK: - StepAction

extension StepAction {
    /// Convert a ChapterScript action DTO into a runtime `StepAction`.
    /// Throws on `.unknown` (forward-compat case the engine can't represent).
    public init(dto: StepActionDTO) throws {
        switch dto {

        // Entity
        case .showEntity(let name):       self = .showEntity(name: name)
        case .hideEntity(let name):       self = .hideEntity(name: name)
        case .moveEntity(let m):          self = .moveEntity(MoveAction(m))
        case .scaleEntity(let name, let mult, let dur, let timing):
            self = .scaleEntity(name: name, multiplier: mult, duration: dur, timing: StepTimingFunction(timing))
        case .fadeEntity(let f):          self = .fadeEntity(FadeAction(f))
        case .persistEntity(let name):    self = .persistEntity(name: name)
        case .unpersistEntity(let name):  self = .unpersistEntity(name: name)
        case .revealEntity(let r):        self = .revealEntity(RevealAction(r))

        // Attachments
        case .showAttachment(let id):                            self = .showAttachment(id: id)
        case .hideAttachment(let id):                            self = .hideAttachment(id: id)
        case .fadeAttachment(let id, let opacity, let duration): self = .fadeAttachment(id: id, opacity: opacity, duration: duration)
        case .setAttachmentView(let id, let viewId):             self = .setAttachmentView(id: id, viewId: viewId)
        case .positionAttachment(let id, let pos, let yOnly):
            self = .positionAttachment(id: id, headRelativePosition: SIMD3(pos), headYOnly: yOnly)

        // Audio
        case .playAudio(let a):                       self = .playAudio(AudioAction(a))
        case .stopAudio(let channel):                 self = .stopAudio(channel: channel)
        case .fadeAudio(let channel, let to, let d):  self = .fadeAudio(channel: channel, to: to, duration: d)
        case .onAudioComplete(let channel, let then):
            self = .onAudioComplete(channel: channel, then: try then.map { try StepAction(dto: $0) })

        // Video
        case .playVideo(let v):       self = .playVideo(VideoAction(v))
        case .prepareVideo(let v):    self = .prepareVideo(VideoAction(v))
        case .stopVideo(let channel): self = .stopVideo(channel: channel)

        // Effects
        case .showPulseRing(let cfg):   self = .showPulseRing(PulseRingConfig(cfg))
        case .hidePulseRing:            self = .hidePulseRing
        case .startSparkBurst(let cfg): self = .startSparkBurst(SparkBurstConfig(cfg))
        case .stopSparkBurst:           self = .stopSparkBurst

        // Audio mix
        case .setMasterVolume(let v):                 self = .setMasterVolume(v)
        case .setCategoryVolume(let cat, let vol):    self = .setCategoryVolume(category: cat, volume: vol)

        // Audio zones
        case .addAudioZone(let zone):    self = .addAudioZone(AudioZone(zone))
        case .removeAudioZone(let id):   self = .removeAudioZone(id: id)
        case .removeAllAudioZones:       self = .removeAllAudioZones

        // Audio bus
        case .setBusVolume(let bus, let v):       self = .setBusVolume(busId: bus, volume: v)
        case .setBusEffect(let bus, let effect):  self = .setBusEffect(busId: bus, effect: AudioEffect(effect))
        case .removeBusEffect(let bus, let effect): self = .removeBusEffect(busId: bus, effect: AudioEffect(effect))

        // Gesture
        case .enableGesture(let entity):   self = .enableGesture(entity: entity)
        case .disableGesture(let entity):  self = .disableGesture(entity: entity)

        // System
        case .setUpperLimbVisibility(let v):   self = .setUpperLimbVisibility(Visibility(v))
        case .setKeyboardPassthrough(let on):  self = .setKeyboardPassthrough(on)

        // Custom (parameters dropped — runtime .custom only carries id)
        case .custom(let id, _):
            self = .custom(id: id)

        // Animate motion — curves carry through directly; format types are reused.
        case .animateMotion(let m):
            self = .animateMotion(AnimateMotionAction(
                entity: m.entity,
                position: m.position,
                scale: m.scale,
                rotation: m.rotation,
                duration: m.duration
            ))

        // Forward-compat
        case .unknown(let name, _):
            throw ChapterScriptRuntimeError.unsupportedAction("unknown:\(name)")
        }
    }
}

// MARK: - StepGate / VisibilityState / CompletionAction

private extension StepGate {
    public init(_ dto: StepGateDTO) {
        self.init(type: GateType(dto.type), timeout: dto.timeout, prompt: dto.prompt)
    }
}

private extension VisibilityState {
    public init(_ dto: VisibilityStateDTO) {
        self.init(
            orb: dto.entities["orb"] ?? false,
            cube: dto.entities["cube"] ?? false,
            cylinder: dto.entities["cylinder"] ?? false,
            cone: dto.entities["cone"] ?? false,
            pulseRing: dto.entities["pulseRing"] ?? false,
            sparkBurst: dto.entities["sparkBurst"] ?? false
        )
    }
}

private extension CompletionAction {
    public init(_ dto: CompletionActionDTO) {
        switch dto {
        case .holdOnLastStep:                         self = .holdOnLastStep
        case .transitionTo(let phase, let visibility): self = .transitionTo(phase: phase, visibility: VisibilityState(visibility))
        case .autoAdvance(let nextChapterId):          self = .autoAdvance(nextChapterId: nextChapterId)
        case .dismissToHome:                           self = .dismissToHome
        }
    }
}

// MARK: - ScheduledAction / StepDefinition / ChapterDefinition

private extension ScheduledAction {
    public init(_ dto: ScheduledActionDTO) throws {
        self.init(at: dto.at, action: try StepAction(dto: dto.action))
    }
}

extension StepDefinition {
    public init(dto: StepDefinitionDTO) throws {
        self.init(
            id: dto.id,
            name: dto.name,
            duration: dto.duration,
            actions: try dto.actions.map { try StepAction(dto: $0) },
            scheduledActions: try dto.scheduledActions.map { try ScheduledAction($0) },
            gate: dto.gate.map { StepGate($0) }
        )
    }
}

extension ChapterDefinition {
    public init(dto: ChapterDefinitionDTO) throws {
        self.init(
            id: dto.id,
            name: dto.name,
            phase: dto.phase,
            presentation: ChapterPresentation(dto.presentation),
            immersiveBackdrop: dto.immersiveBackdrop.map { ChapterBackdrop($0) },
            steps: try dto.steps.map { try StepDefinition(dto: $0) },
            visibility: VisibilityState(dto.visibility),
            onComplete: CompletionAction(dto.onComplete)
        )
    }
}

extension ChapterPresentation {
    public init(_ dto: ChapterScript.ChapterPresentation) {
        switch dto {
        case .immersive: self = .immersive
        case .mixed:     self = .mixed
        case .windowed:  self = .windowed
        }
    }
}

extension ChapterBackdrop {
    public init(_ dto: ImmersiveBackdropSpec) {
        switch dto {
        case .video(let file, let layout, let field, let radius, let loop):
            self = .video(
                file: file,
                layout: VideoLayout(dtoLayout: layout),
                field: ImmersiveField(dtoField: field),
                radius: radius,
                loop: loop
            )
        case .image(let file, let field, let radius):
            self = .image(
                file: file,
                field: ImmersiveField(dtoField: field),
                radius: radius
            )
        case .usdz(let assetId):
            self = .usdz(assetId: assetId)
        }
    }
}

extension VideoLayout {
    public init(dtoLayout: ChapterScript.VideoLayout) {
        switch dtoLayout {
        case .mono: self = .mono
        case .sideBySide: self = .sideBySide
        case .overUnder: self = .overUnder
        case .multiviewHEVC: self = .multiviewHEVC
        }
    }
}

extension ImmersiveField {
    public init(dtoField: ChapterScript.ImmersiveField) {
        switch dtoField {
        case .equirect360: self = .equirect360
        case .equirect180: self = .equirect180
        }
    }
}

// MARK: - ExperienceDocument loading

extension ChapterDefinition {
    /// Find `chapterId` in `document.chapters` and convert it to a runtime chapter.
    static public func from(document: ExperienceDocument, chapterId: String) throws -> ChapterDefinition {
        guard let dto = document.chapters.first(where: { $0.id == chapterId }) else {
            throw ChapterScriptRuntimeError.unsupportedDocument(
                reason: "chapter id '\(chapterId)' not found in document '\(document.id)'"
            )
        }
        return try ChapterDefinition(dto: dto)
    }
}
