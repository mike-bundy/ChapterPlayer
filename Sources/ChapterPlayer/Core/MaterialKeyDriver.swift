//
//  MaterialKeyDriver.swift
//  ChapterPlayer
//
//  PLAYING KEYED MATERIALS (FL-14, the animation half). The runtime half of
//  the material sampler: what paint an Object wears NOW, on the AUTHORED
//  clock (`sequenceAnimationTime`) — so a viewer held at a gate sees the
//  color that belongs to the moment they are held in, exactly as a caption,
//  a fade or a backdrop holds.
//
//  Modeled on `CaptionCueDriver`, and deliberately NOT part of
//  `SequenceEngine`: a keyed material is not a step, a gate or an action.
//  Polling, not scheduling, for the same five reasons (pause, gate, seek,
//  scrub, next-sequence staleness).
//
//  MIRRORED CONTRACT NOTE: the sampling rule — keyed channels replace the
//  stored value, unkeyed ones keep it, colors key per component, and a
//  track for a slot with no stored override MINTS one — mirrors
//  `MaestroKit.MaterialResolution.sampled`. ChapterPlayer cannot depend on
//  MaestroKit. CHANGE ONE, CHANGE BOTH.
//
//  IT PRESENTS ORDINARY OVERRIDES. `MaterialRealizationRuntime.apply`
//  already knows how to wear a `MaterialOverrideSpec`, and it does not learn
//  that a value came from a curve — the same integration the Mac has, so
//  the two hosts cannot drift into two answers.
//
//  DEFERRED VISION RUNTIME QA: this compiles for visionOS and is unit-tested
//  through MaestroVision's suite. Nobody has watched a material animate on a
//  headset from this machine, and a green suite is not that claim.
//

import Foundation
import ChapterScript
import os.log

/// What the driver needs from whatever wears the paint. A protocol so the
/// driver can be exercised without a RealityKit scene.
@MainActor
public protocol MaterialKeyPresenting: AnyObject {
    /// Wear exactly these overrides on this Object. Called only when the
    /// sampled result CHANGES — rebuilding a PBR material every tick for a
    /// value nobody keyed is the cost this guards against.
    func presentMaterials(_ overrides: [MaterialOverrideSpec], forEntity entityId: String)
}

@MainActor
public final class MaterialKeyDriver {

    private let logger = Logger(subsystem: "ChapterPlayer", category: "MaterialKey")

    private weak var presenter: MaterialKeyPresenting?

    /// One Object's keyed slots, with the stored overrides they rest on.
    private struct BoundEntity {
        let entityId: String
        let stored: [MaterialOverrideSpec]
        let tracks: [MaterialKeyTrack]
    }

    private var bound: [BoundEntity] = []
    private var clock: (() -> TimeInterval)?
    private var ticker: Task<Void, Never>?
    /// The last presented result per entity, so an unchanged frame presents
    /// nothing.
    private var lastPresented: [String: [MaterialOverrideSpec]] = [:]

    /// Paint changes are perceived continuously rather than at cut points,
    /// so this ticks faster than the caption driver — but still nowhere near
    /// frame rate, because a material rebuild is not free and a 20 Hz ramp
    /// is imperceptible from a smooth one.
    private static let tickInterval: Duration = .milliseconds(50)

    public init(presenter: MaterialKeyPresenting) {
        self.presenter = presenter
    }

    // MARK: - Lifecycle

    /// Bind a Sequence's material key tracks and start following the clock.
    public func begin(tracks: [MaterialKeyTrack]?,
                      entities: [EntityDefinition],
                      clock: @escaping () -> TimeInterval) {
        stop(tearDown: false)
        let keyed = (tracks ?? []).filter { $0.hasAnyKeys }
        guard !keyed.isEmpty else { return }
        let byEntity = Dictionary(grouping: keyed, by: \.entityId)
        self.bound = byEntity.keys.sorted().compactMap { entityId in
            guard let definition = entities.first(where: { $0.id == entityId })
            else {
                // A track naming an Object this Chapter no longer has is
                // KEPT in the document and skipped here — the same rule an
                // orphaned override follows. It is not the player's business
                // to decide the Object will never come back.
                logger.info("[materialkey] no entity for track \(entityId, privacy: .public)")
                return nil
            }
            return BoundEntity(entityId: entityId,
                               stored: definition.materialOverrides ?? [],
                               tracks: byEntity[entityId] ?? [])
        }
        self.clock = clock
        self.lastPresented = [:]
        guard !bound.isEmpty else { return }
        logger.info("[materialkey] following \(self.bound.count) object(s)")
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
        if tearDown {
            // RESTORE THE STORED LOOK. Leaving the last sampled frame on the
            // Object would make the paint depend on where the viewer happened
            // to leave the Sequence.
            for entity in bound where lastPresented[entity.entityId] != nil {
                presenter?.presentMaterials(entity.stored, forEntity: entity.entityId)
            }
        }
        bound = []
        lastPresented = [:]
    }

    // MARK: - The re-sample

    func tick() {
        guard let clock else { return }
        let time = clock()
        for entity in bound {
            let sampled = Self.sampled(stored: entity.stored,
                                       tracks: entity.tracks, at: time)
            guard lastPresented[entity.entityId] != sampled else { continue }
            lastPresented[entity.entityId] = sampled
            presenter?.presentMaterials(sampled, forEntity: entity.entityId)
        }
    }

    /// MIRRORS `MaestroKit.MaterialResolution.sampled` — change one, change
    /// both.
    ///
    /// A track for a slot with no stored override MINTS one, because "this
    /// slot is animated" is itself an authored fact; dropping it would make
    /// keying a file's own value impossible.
    public static func sampled(stored: [MaterialOverrideSpec],
                               tracks: [MaterialKeyTrack],
                               at time: TimeInterval) -> [MaterialOverrideSpec] {
        var bySlot: [Int: MaterialOverrideSpec] = [:]
        for override in stored { bySlot[override.slot] = override }
        var order = stored.map(\.slot)

        for track in tracks where track.hasAnyKeys {
            var spec = bySlot[track.slot] ?? MaterialOverrideSpec(slot: track.slot)
            if bySlot[track.slot] == nil { order.append(track.slot) }
            apply(track, at: time, to: &spec)
            bySlot[track.slot] = spec
        }
        var seen = Set<Int>()
        return order.compactMap { slot in
            guard seen.insert(slot).inserted else { return nil }
            return bySlot[slot]
        }
    }

    private static func apply(_ track: MaterialKeyTrack, at time: TimeInterval,
                              to spec: inout MaterialOverrideSpec) {
        func value(_ channel: MaterialKeyChannel, rest: Float) -> Float? {
            let curve = track[channel]
            guard curve.isAnimated else { return nil }
            let sampled = SequenceAnimationEvaluator.evaluate(curve, at: time, rest: rest)
            guard let range = channel.renderRange else { return sampled }
            return min(max(sampled, range.lowerBound), range.upperBound)
        }

        let baseRest = spec.baseColor ?? ColorRGBA(r: 1, g: 1, b: 1, a: 1)
        if MaterialKeyChannel.Property.baseColor.channels.contains(where: {
            track[$0].isAnimated
        }) {
            spec.baseColor = ColorRGBA(
                r: value(.baseColorRed, rest: baseRest.r) ?? baseRest.r,
                g: value(.baseColorGreen, rest: baseRest.g) ?? baseRest.g,
                b: value(.baseColorBlue, rest: baseRest.b) ?? baseRest.b,
                a: value(.baseColorAlpha, rest: baseRest.a) ?? baseRest.a)
        }
        let emissiveRest = spec.emissiveColor ?? ColorRGBA(r: 0, g: 0, b: 0, a: 1)
        if MaterialKeyChannel.Property.emissiveColor.channels.contains(where: {
            track[$0].isAnimated
        }) {
            spec.emissiveColor = ColorRGBA(
                r: value(.emissiveRed, rest: emissiveRest.r) ?? emissiveRest.r,
                g: value(.emissiveGreen, rest: emissiveRest.g) ?? emissiveRest.g,
                b: value(.emissiveBlue, rest: emissiveRest.b) ?? emissiveRest.b,
                a: emissiveRest.a)
        }
        if let v = value(.roughness, rest: spec.roughness ?? 0.5) { spec.roughness = v }
        if let v = value(.metallic, rest: spec.metallic ?? 0) { spec.metallic = v }
        if let v = value(.opacity, rest: spec.opacity ?? 1) { spec.opacity = v }
        if let v = value(.emissiveIntensity, rest: spec.emissiveIntensity ?? 0) {
            spec.emissiveIntensity = v
        }
    }
}

// MARK: - The core wears the paint

extension ChapterPlayerCore: MaterialKeyPresenting {

    /// Wear the sampled overrides on the named Object.
    ///
    /// THE SAME REALIZATION A STORED OVERRIDE GETS. `EntityFactory` applies
    /// the authored looks at load through `MaterialRealizationRuntime`; this
    /// is that call again with a different set of values, which is the whole
    /// of what "the material is animated" means at runtime. If the two ever
    /// became different code paths, a keyed material would render one way
    /// and a static one another.
    public func presentMaterials(_ overrides: [MaterialOverrideSpec],
                                 forEntity entityId: String) {
        guard let entity = documentEntities?.entity(named: entityId) else { return }
        MaterialRealizationRuntime.apply(overrides, under: entity) { [weak self] file in
            self?.loadedExperience?.mediaResolver.url(for: file, kind: .image)
        }
    }
}
