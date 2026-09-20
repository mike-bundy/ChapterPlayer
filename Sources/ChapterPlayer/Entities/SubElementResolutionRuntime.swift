//
//  SubElementResolutionRuntime.swift
//  ChapterPlayer
//
//  REALIZATION OF ALREADY-STORED USD PRIM PATHS (FL-16).
//
//  USDKit is intentionally absent: it discovers paths, while the player only
//  consumes the exact `(objectId, primPath)` facts already in the Chapter.
//  This mirrors MaestroKit.SubElementResolution because ChapterPlayer cannot
//  depend on the editor package. Change the two resolution/composition rules
//  together.
//

import Foundation
import RealityKit
import ChapterScript
import simd

private struct RuntimeSubElementRestComponent: Component {
    var transform: Transform
    var isEnabled: Bool
}

@MainActor
public enum SubElementResolutionRuntime {
    public struct Resolution {
        public let entity: Entity
        public let residualPath: String
        public var transformable: Bool { residualPath.isEmpty }
    }

    private static let registration: Void = {
        RuntimeSubElementRestComponent.registerComponent()
    }()

    /// Resolve one stored prim path against a loaded subtree. The walk is
    /// `MaestroKit.SubElementResolution.resolve`, component for component:
    /// the two used to differ, and the difference was live. The player
    /// resolves under the Object's CONTAINER (named by object id), with the
    /// loaded stage one level down, so a stage root RealityKit left
    /// anonymous resolved nothing, and a root that carried the first
    /// component's name "resolved" to the whole model with the full path as
    /// residual - a part's visibility then hid the Object.
    public static func resolve(_ primPath: String, under root: Entity) -> Resolution? {
        let components = primPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        var cursor = root
        var consumed = 0
        while consumed < components.count {
            let component = components[consumed]

            // The cursor may BE the prim (the root prim, when the loaded
            // entity carries its name). Anonymous containers around a loaded
            // stage have no USD prim identity, so they are transparent to a
            // prim path - but only while the anonymous route is unique.
            if cursor.name == component {
                consumed += 1
                continue
            }
            let matches = cursor.children.filter { $0.name == component }
            if matches.count == 1 {
                cursor = matches[0]
                consumed += 1
            } else if matches.count > 1 {
                // Ambiguous by NAME at this level - refuse to guess.
                return nil
            } else if cursor.children.filter({ $0.name.isEmpty }).count == 1,
                      let anonymous = cursor.children.first(where: { $0.name.isEmpty }) {
                cursor = anonymous
            } else if cursor.children.contains(where: { $0.name.isEmpty }) {
                // Two anonymous routes are as ambiguous as duplicate names.
                return nil
            } else {
                break
            }
        }
        guard consumed > 0 else { return nil }
        return Resolution(entity: cursor,
                          residualPath: components.dropFirst(consumed)
                            .joined(separator: "/"))
    }

    @discardableResult
    public static func apply(
        _ overrides: [SubElementOverride],
        under root: Entity,
        textureURL: (String) -> URL?
    ) -> [String] {
        _ = registration
        restoreOffsets(under: root)
        var unresolved: [String] = []
        for override in overrides where !override.isEmpty {
            guard let hit = resolve(override.primPath, under: root) else {
                unresolved.append(override.primPath)
                continue
            }
            if override.isVisible != nil || (override.transformOffset != nil && hit.transformable) {
                hit.entity.components.set(RuntimeSubElementRestComponent(
                    transform: hit.entity.transform, isEnabled: hit.entity.isEnabled))
            }
            if let visible = override.isVisible { hit.entity.isEnabled = visible }
            if let offset = override.transformOffset, hit.transformable {
                hit.entity.transform = Transform(
                    matrix: matrix(offset) * hit.entity.transform.matrix)
            }
            if let materials = override.materialOverrides, !materials.isEmpty {
                MaterialRealizationRuntime.apply(materials, under: hit.entity,
                                                 textureURL: textureURL)
            }
        }
        return unresolved
    }

    private static func restoreOffsets(under root: Entity) {
        var stack = [root]
        while let entity = stack.popLast() {
            if let stored = entity.components[RuntimeSubElementRestComponent.self] {
                entity.transform = stored.transform
                entity.isEnabled = stored.isEnabled
                entity.components.remove(RuntimeSubElementRestComponent.self)
            }
            stack.append(contentsOf: entity.children)
        }
    }

    private static func matrix(_ value: TransformData) -> simd_float4x4 {
        let rotation = simd_quatf(vector: SIMD4(
            value.rotation.x, value.rotation.y, value.rotation.z, value.rotation.w))
        var result = simd_float4x4(rotation)
        result.columns.0 *= value.scale.x
        result.columns.1 *= value.scale.y
        result.columns.2 *= value.scale.z
        result.columns.3 = SIMD4(
            value.position.x, value.position.y, value.position.z, 1)
        return result
    }
}
