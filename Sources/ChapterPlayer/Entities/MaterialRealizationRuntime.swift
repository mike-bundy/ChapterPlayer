//
//  MaterialRealizationRuntime.swift
//  ChapterPlayer
//
//  THE RUNTIME ADAPTER FOR FL-14's ONE RESOLVER — where CD-3 and CD-4
//  actually close: the headset resolves through the SAME
//  `MaterialResolution` contract shape and applies INDEX BY INDEX,
//  container-aware. Never `materials = [one]`.
//
//  The resolver itself lives in MaestroKit (an editor package the player
//  does not link), so the player carries the same composition rule in its
//  minimal runtime form: a nil field is the file's own value; an untouched
//  slot keeps the file's material INSTANCE; an override whose slot the
//  file no longer has is ignored here and REPORTED by the editors.
//

import Foundation
import RealityKit
import UIKit
import ChapterScript

@MainActor
enum MaterialRealizationRuntime {

    static func modelEntities(under root: Entity) -> [ModelEntity] {
        var out: [ModelEntity] = []
        var stack: [Entity] = [root]
        while let e = stack.popLast() {
            if let model = e as? ModelEntity { out.append(model) }
            stack.append(contentsOf: e.children.reversed())
        }
        return out
    }

    /// Apply the authored per-slot overrides to a loaded subtree.
    static func apply(_ overrides: [MaterialOverrideSpec],
                      under root: Entity,
                      textureURL: (String) -> URL?) {
        var bySlot: [Int: MaterialOverrideSpec] = [:]
        for spec in overrides where !spec.isEmpty { bySlot[spec.slot] = spec }
        guard !bySlot.isEmpty else { return }
        var cursor = 0
        for model in modelEntities(under: root) {
            let count = model.model?.materials.count ?? 0
            for index in 0..<count {
                defer { cursor += 1 }
                guard let spec = bySlot[cursor] else { continue }
                if let material = realize(spec, existing: model.model?.materials[index],
                                          textureURL: textureURL) {
                    model.model?.materials[index] = material
                }
            }
        }
    }

    private static func realize(_ spec: MaterialOverrideSpec,
                                existing: (any RealityKit.Material)?,
                                textureURL: (String) -> URL?) -> (any RealityKit.Material)? {
        // A ShaderGraphMaterial keeps its own graph; only exposed inputs move.
        if var graph = existing as? ShaderGraphMaterial {
            guard let inputs = spec.shaderInputs, !inputs.isEmpty else { return nil }
            for (name, value) in inputs where graph.parameterNames.contains(name) {
                if let number = value.numberValue {
                    try? graph.setParameter(name: name, value: .float(Float(number)))
                } else if let color = value.colorValue {
                    try? graph.setParameter(name: name, value: .color(UIColor(
                        red: CGFloat(color.r), green: CGFloat(color.g),
                        blue: CGFloat(color.b), alpha: CGFloat(color.a))))
                }
            }
            return graph
        }
        let filePBR = existing as? PhysicallyBasedMaterial
        let fileUnlit = existing as? UnlitMaterial
        let fileTint = filePBR?.baseColor.tint ?? fileUnlit?.color.tint
        let opacity = spec.opacity ?? 1
        let tint: UIColor
        if let c = spec.baseColor {
            tint = UIColor(red: CGFloat(c.r), green: CGFloat(c.g),
                           blue: CGFloat(c.b), alpha: CGFloat(opacity))
        } else {
            tint = (fileTint ?? .white).withAlphaComponent(CGFloat(opacity))
        }
        if spec.unlit ?? (fileUnlit != nil) {
            var unlit = UnlitMaterial(color: tint)
            unlit.blending = opacity < 1
                ? .transparent(opacity: .init(floatLiteral: opacity)) : .opaque
            return unlit
        }
        var pbr = filePBR ?? PhysicallyBasedMaterial()
        pbr.baseColor.tint = tint
        if let texture = spec.baseColorTextureSourceId, let url = textureURL(texture),
           let resource = try? TextureResource.load(contentsOf: url,
                                                    options: .init(semantic: .color)) {
            pbr.baseColor.texture = .init(resource)
        }
        if let normal = spec.normalTextureSourceId, let url = textureURL(normal),
           let resource = try? TextureResource.load(contentsOf: url,
                                                    options: .init(semantic: .normal)) {
            pbr.normal.texture = .init(resource)
        }
        if let roughness = spec.roughness { pbr.roughness = .init(floatLiteral: roughness) }
        if let metallic = spec.metallic { pbr.metallic = .init(floatLiteral: metallic) }
        if let emissive = spec.emissiveColor {
            pbr.emissiveColor = .init(color: UIColor(
                red: CGFloat(emissive.r), green: CGFloat(emissive.g),
                blue: CGFloat(emissive.b), alpha: 1))
        }
        if let intensity = spec.emissiveIntensity { pbr.emissiveIntensity = intensity }
        if spec.blending == .alpha || opacity < 1 {
            pbr.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return pbr
    }
}
