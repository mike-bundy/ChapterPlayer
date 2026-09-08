//
//  SubElementKeyDriver.swift
//  ChapterPlayer
//
//  PER-FRAME STORED-PRIM-PATH PRESENTATION (FL-16).
//

import Foundation
import ChapterScript
import simd

@MainActor
public protocol SubElementKeyPresenting: AnyObject {
    func presentSubElements(_ overrides: [SubElementOverride], forObject objectId: String)
}

@MainActor
public protocol SubElementActionExecuting: AnyObject {
    func executeSubElementAction(_ command: SubElementActionDTO)
}

@MainActor
public final class SubElementKeyDriver {
    private weak var presenter: SubElementKeyPresenting?

    private struct BoundObject {
        let objectId: String
        let stored: [SubElementOverride]
        let tracks: [SubElementKeyTrack]
    }

    private var bound: [BoundObject] = []
    private var clock: (() -> TimeInterval)?
    private var ticker: Task<Void, Never>?
    private var lastPresented: [String: [SubElementOverride]] = [:]
    private static let tickInterval: Duration = .milliseconds(16)

    public init(presenter: SubElementKeyPresenting) {
        self.presenter = presenter
    }

    public func begin(tracks: [SubElementKeyTrack]?,
                      entities: [EntityDefinition],
                      clock: @escaping () -> TimeInterval) {
        stop(tearDown: false)
        let keyed = (tracks ?? []).filter { $0.hasAnyKeys }
        guard !keyed.isEmpty else { return }
        let grouped = Dictionary(grouping: keyed, by: \.entityId)
        bound = grouped.keys.sorted().compactMap { objectId in
            guard let definition = entities.first(where: { $0.id == objectId }) else {
                return nil
            }
            return BoundObject(objectId: objectId,
                               stored: definition.subElements ?? [],
                               tracks: grouped[objectId] ?? [])
        }
        self.clock = clock
        lastPresented = [:]
        guard !bound.isEmpty else { return }
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
            for object in bound where lastPresented[object.objectId] != nil {
                presenter?.presentSubElements(object.stored, forObject: object.objectId)
            }
        }
        bound = []
        lastPresented = [:]
    }

    public func tick() {
        guard let clock else { return }
        let time = clock()
        for object in bound {
            let value = Self.sampled(stored: object.stored,
                                     tracks: object.tracks, at: time)
            guard lastPresented[object.objectId] != value else { continue }
            lastPresented[object.objectId] = value
            presenter?.presentSubElements(value, forObject: object.objectId)
        }
    }

    /// Mirrors `MaestroKit.SubElementResolution.sampled` exactly. The stored
    /// offset is the rest and unkeyed channels retain it.
    public static func sampled(stored: [SubElementOverride],
                               tracks: [SubElementKeyTrack],
                               at time: TimeInterval) -> [SubElementOverride] {
        var byPath = Dictionary(uniqueKeysWithValues: stored.map { ($0.primPath, $0) })
        var order = stored.map(\.primPath)
        for track in tracks where track.hasAnyKeys {
            var value = byPath[track.primPath]
                ?? SubElementOverride(primPath: track.primPath)
            if byPath[track.primPath] == nil { order.append(track.primPath) }
            value.transformOffset = sampledOffset(track, at: time,
                                                  rest: value.transformOffset)
            byPath[track.primPath] = value
        }
        var seen = Set<String>()
        return order.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return byPath[path]
        }
    }

    private static func sampledOffset(_ track: SubElementKeyTrack,
                                      at time: TimeInterval,
                                      rest: TransformData?) -> TransformData {
        let base = rest ?? TransformData(
            position: Vec3(x: 0, y: 0, z: 0),
            rotation: Quat(x: 0, y: 0, z: 0, w: 1),
            scale: Vec3(x: 1, y: 1, z: 1))
        func value(_ channel: AnimationChannel, _ rest: Float) -> Float {
            let curve = track[channel]
            guard curve.isAnimated else { return rest }
            return SequenceAnimationEvaluator.evaluate(curve, at: time, rest: rest)
        }
        let restEuler = AnimationEulerMath.quatToEuler(
            simd_quatf(vector: SIMD4(base.rotation.x, base.rotation.y,
                                    base.rotation.z, base.rotation.w)),
            order: track.rotationOrder)
        let euler = SIMD3(value(.rx, restEuler.x), value(.ry, restEuler.y),
                          value(.rz, restEuler.z))
        let rotation = AnimationEulerMath.eulerToQuat(euler, order: track.rotationOrder)
        return TransformData(
            position: Vec3(x: value(.tx, base.position.x),
                           y: value(.ty, base.position.y),
                           z: value(.tz, base.position.z)),
            rotation: Quat(x: rotation.imag.x, y: rotation.imag.y,
                           z: rotation.imag.z, w: rotation.real),
            scale: Vec3(x: value(.sx, base.scale.x),
                        y: value(.sy, base.scale.y),
                        z: value(.sz, base.scale.z)))
    }
}

extension ChapterPlayerCore: SubElementKeyPresenting {
    public func presentSubElements(_ overrides: [SubElementOverride],
                                   forObject objectId: String) {
        guard let root = documentEntities?.entity(named: objectId) else { return }
        _ = SubElementResolutionRuntime.apply(
            overrides, under: root,
            textureURL: { [weak self] file in
                self?.loadedExperience?.mediaResolver.url(for: file, kind: .image)
            })
    }
}

extension ChapterPlayerCore: SubElementActionExecuting {
    public func executeSubElementAction(_ command: SubElementActionDTO) {
        guard let definition = loadedExperience?.document.entities.first(where: {
            $0.id == command.target.objectId
        }) else { return }
        var overrides = definition.subElements ?? []
        let index = overrides.firstIndex { $0.primPath == command.target.primPath }
        var effective = index.map { overrides[$0] }
            ?? SubElementOverride(primPath: command.target.primPath)
        if let visible = command.isVisible { effective.isVisible = visible }
        if let transform = command.transformOffset { effective.transformOffset = transform }
        if let materials = command.materialOverrides { effective.materialOverrides = materials }
        if let index { overrides[index] = effective } else { overrides.append(effective) }
        presentSubElements(overrides, forObject: command.target.objectId)
    }
}
