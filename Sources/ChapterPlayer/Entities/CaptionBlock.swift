//
//  CaptionBlock.swift
//  ChapterPlayer
//
//  THE MIRROR of `MaestroKit.CaptionGeometry` (FL-08): a caption block is
//  flat shaped text (the mirrored `TitleMesh` recipe at zero depth) on an
//  unlit legibility plate, with per-run bold / italic / color / underline,
//  the line limit, the outline halo and the angular-size rule — the SAME
//  recipe the Mac Viewer and export draw, so a Chapter plays as authored.
//  MaestroVision's `CaptionSeamTests` compare the two builds. Change one,
//  change both.
//

import Foundation
import ChapterScript
import RealityKit
import UIKit

@MainActor
public enum CaptionBlock {

    public struct Underline {
        public let mesh: MeshResource
        public let material: UnlitMaterial
        public let position: SIMD3<Float>
    }

    public struct Result {
        public let textMesh: MeshResource
        public let textMaterials: [UnlitMaterial]
        public let plateMesh: MeshResource?
        public let plateMaterial: UnlitMaterial?
        public let outlineMesh: MeshResource?
        public let outlineMaterial: UnlitMaterial?
        public let underlines: [Underline]
        public let textSize: SIMD2<Float>
        public let truncatedLines: Int
        public let shapedText: String
    }

    /// MIRRORS `MaestroKit.CaptionAuthoring.defaultStyle` through
    /// `CaptionCueDriver.defaultStyle` — one copy in the player.
    static var defaultStyle: CaptionStyle { CaptionCueDriver.defaultStyle }

    public static let platePadding: Float = 0.02
    public static let plateOffset: Float = 0.004
    public static let outlineOffset: Float = 0.002
    public static let underlineOffset: Float = 0.001

    /// Mirror of `CaptionGeometry.capHeight`.
    public static func capHeight(style: CaptionStyle) -> Float {
        if let angle = style.angularSize, angle > 0.01 {
            let distance = style.distance ?? defaultStyle.distance ?? 1.8
            return distance * tan(angle * .pi / 180)
        }
        return style.fontSize ?? defaultStyle.fontSize ?? 0.045
    }

    /// Mirror of `CaptionGeometry.spec`.
    public static func spec(text: String, style: CaptionStyle) -> TextSpec {
        var spec = TextSpec(text: text)
        spec.fontSize = capHeight(style: style)
        spec.color = style.color ?? ColorRGBA(r: 1, g: 1, b: 1, a: 1)
        spec.maxWidth = style.maxWidth ?? defaultStyle.maxWidth
        spec.fontFamily = style.fontFamily
        spec.fontWeight = style.fontWeight
        spec.alignmentX = .center
        spec.extrusionDepth = 0
        return spec
    }

    public static func build(text: String, style: CaptionStyle,
                             runs: [CaptionStyleRun]? = nil) throws -> Result {
        var spec = Self.spec(text: text, style: style)
        let limit = style.maxLineCount ?? defaultStyle.maxLineCount ?? 2
        let cut = CaptionRunLayout.truncate(spec: spec, toLines: limit,
                                            styleRuns: CaptionRunLayout.styleRuns(runs ?? []))
        spec.text = cut.text
        let runs = CaptionRunLayout.clip(runs ?? [], to: cut.text)
        let styled = CaptionRunLayout.styleRuns(runs)

        let built = try TitleMesh.build(spec: spec, styleRuns: styled)
        let bounds = built.mesh.bounds
        let size = SIMD2<Float>(bounds.extents.x, bounds.extents.y)

        let base = spec.color
        var materials: [UnlitMaterial] = [unlit(base)]
        var mesh = built.mesh
        let needsLayout = runs.contains { $0.color != nil || $0.underline == true }
        let layout = needsLayout
            ? CaptionRunLayout.glyphSpans(spec: spec, runs: runs, styleRuns: styled, mesh: mesh)
            : []
        var slotByRun: [Int: UInt32] = [:]
        for (index, run) in runs.enumerated() {
            guard let color = run.color else { continue }
            slotByRun[index] = UInt32(materials.count)
            materials.append(unlit(color))
        }
        if !slotByRun.isEmpty {
            mesh = try CaptionRunLayout.recolored(mesh, spans: layout, slotByRun: slotByRun)
        }

        var underlines: [Underline] = []
        let thickness = max(spec.fontSize * 0.06, 0.001)
        for (index, run) in runs.enumerated() where run.underline == true {
            let owned = layout.filter { $0.runIndex == index }
            for line in Set(owned.map(\.lineIndex)).sorted() {
                let onLine = owned.filter { $0.lineIndex == line }
                guard let minX = onLine.map(\.minX).min(),
                      let maxX = onLine.map(\.maxX).max(),
                      let baseline = onLine.map(\.baselineY).min() else { continue }
                let plate = MeshResource.generatePlane(width: max(maxX - minX, 0.001),
                                                      height: thickness)
                underlines.append(Underline(
                    mesh: plate, material: unlit(run.color ?? base),
                    position: SIMD3<Float>((minX + maxX) / 2,
                                           baseline - spec.fontSize * 0.18,
                                           underlineOffset)))
            }
        }

        var plateMesh: MeshResource?
        var plateMaterial: UnlitMaterial?
        let back = style.backgroundColor ?? defaultStyle.backgroundColor
        if let back, back.a > 0.01 {
            plateMesh = .generatePlane(width: size.x + platePadding * 2,
                                       height: size.y + platePadding * 2,
                                       cornerRadius: 0.012)
            plateMaterial = unlit(ColorRGBA(r: back.r, g: back.g, b: back.b, a: 1), opacity: back.a)
        }

        var outlineMesh: MeshResource?
        var outlineMaterial: UnlitMaterial?
        if let outline = style.outlineColor, outline.a > 0.001,
           let width = style.outlineWidth, width > 0.0001 {
            let grow = 1 + (2 * width) / max(spec.fontSize, 0.0001)
            outlineMesh = try CaptionRunLayout.outlined(built.mesh, growBy: grow)
            outlineMaterial = unlit(outline)
        }

        return Result(textMesh: mesh, textMaterials: materials,
                      plateMesh: plateMesh, plateMaterial: plateMaterial,
                      outlineMesh: outlineMesh, outlineMaterial: outlineMaterial,
                      underlines: underlines,
                      textSize: size, truncatedLines: cut.removedLines, shapedText: cut.text)
    }

    static func unlit(_ color: ColorRGBA, opacity: Float? = nil) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: UIColor(red: CGFloat(color.r), green: CGFloat(color.g),
                                             blue: CGFloat(color.b), alpha: CGFloat(color.a)))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity ?? color.a))
        return material
    }

    /// Mirror of `CaptionGeometry.makeBlock`.
    public static func makeBlock(_ built: Result, name: String = "caption.block") -> Entity {
        let block = Entity()
        block.name = name
        if let plateMesh = built.plateMesh, let plateMaterial = built.plateMaterial {
            let plate = ModelEntity(mesh: plateMesh, materials: [plateMaterial])
            plate.name = "caption.plate"
            plate.position.z = -plateOffset
            block.addChild(plate)
        }
        let bounds = built.textMesh.bounds
        let centering = SIMD3<Float>(-bounds.center.x, -bounds.center.y, 0)
        if let outlineMesh = built.outlineMesh, let outlineMaterial = built.outlineMaterial {
            let halo = ModelEntity(mesh: outlineMesh, materials: [outlineMaterial])
            halo.name = "caption.outline"
            halo.position = centering + SIMD3<Float>(0, 0, -outlineOffset)
            block.addChild(halo)
        }
        let words = ModelEntity(mesh: built.textMesh, materials: built.textMaterials)
        words.name = "caption.words"
        words.position = centering
        block.addChild(words)
        for underline in built.underlines {
            let plate = ModelEntity(mesh: underline.mesh, materials: [underline.material])
            plate.name = "caption.underline"
            plate.position = centering + underline.position
            block.addChild(plate)
        }
        return block
    }

    /// Mirror of `CaptionGeometry.stackAdvance`.
    public static func stackAdvance(_ built: Result) -> Float {
        built.textSize.y + platePadding * 2 + 0.015
    }

    /// Mirror of `CaptionGeometry.viewerFacingPosition`.
    public static func viewerFacingPosition(style: CaptionStyle) -> SIMD3<Float> {
        let distance = style.distance ?? defaultStyle.distance ?? 1.8
        return SIMD3<Float>(0, -0.22 * distance, -distance)
    }
}
