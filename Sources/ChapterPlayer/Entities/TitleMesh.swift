//
//  TitleMesh.swift
//  ChapterPlayer
//
//  THE MIRRORED TITLE CONTRACT (FL-07). ChapterPlayer cannot depend on
//  MaestroKit, so `MaestroKit.TitleGeometry`'s recipe is DUPLICATED here —
//  same font resolution (cap-height metres), same attributed string, same
//  extrusion options, same material mapping — and MaestroVision's seam test
//  compares the two builds' vertex counts, bounds and material assignment.
//  Change one, change both; the seam test is what enforces it.
//

import Foundation
import CoreText
import RealityKit
import UIKit
import ChapterScript

public enum TitleMesh {

    public static let defaultExtrusionDepth: Float = 0.02

    public struct Result {
        public let mesh: MeshResource
        public let materials: [any Material]
    }

    /// Cap-height-metres font resolution — the mirror of
    /// `MaestroKit.FontResolution.resolve`.
    static func resolveFont(family: String?, weight: Int?, italic: Bool?,
                            capHeightMetres: Float, sourceURL: URL? = nil) -> CTFont {
        let probeSize: CGFloat = 100
        let base: CTFont
        if let sourceURL, let fromFile = fontFromFile(sourceURL, size: probeSize) {
            // A font Source (K11): the file IS the font — the mirror of
            // `MaestroKit.FontResolution.fontFromFile`. Unreadable ⇒ the
            // cascade below, exactly as the editors substitute.
            base = fromFile
        } else if let family, !family.isEmpty {
            var traits: [CFString: Any] = [kCTFontWeightTrait: ctWeight(weight)]
            if italic == true {
                traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue
            }
            let attributes: [CFString: Any] = [
                kCTFontFamilyNameAttribute: family,
                kCTFontTraitsAttribute: traits,
            ]
            base = CTFontCreateWithFontDescriptor(
                CTFontDescriptorCreateWithAttributes(attributes as CFDictionary),
                probeSize, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(.system, probeSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, probeSize, nil)
        }
        let capAtProbe = CTFontGetCapHeight(base)
        let metres = CGFloat(max(capHeightMetres, 0.0001))
        let pointSize = capAtProbe > 0 ? metres * probeSize / capAtProbe : metres
        return CTFontCreateCopyWithAttributes(base, pointSize, nil, nil)
    }

    static func ctWeight(_ weight: Int?) -> CGFloat {
        switch weight ?? 400 {
        case ..<150:      return -0.8
        case 150..<250:   return -0.6
        case 250..<350:   return -0.4
        case 350..<450:   return 0.0
        case 450..<550:   return 0.23
        case 550..<650:   return 0.3
        case 650..<750:   return 0.4
        case 750..<850:   return 0.56
        default:          return 0.62
        }
    }

    /// The measured extruder unit scale — the mirror of
    /// `TitleGeometry.unitsPerPoint()`. Same probe, same fallback.
    @MainActor
    private static var measuredUnitsPerPointCache: CGFloat?

    @MainActor
    static func unitsPerPoint() -> CGFloat {
        if let cached = measuredUnitsPerPointCache { return cached }
        let probePoints: CGFloat = 100
        let font = CTFontCreateWithName("Helvetica" as CFString, probePoints, nil)
        var reference = AttributedString("H")
        reference.font = font as UIFont
        let capPoints = CTFontGetCapHeight(font)
        let fallback = 1.0 / 72.0
        guard capPoints > 0,
              let mesh = try? MeshResource(extruding: reference)
        else {
            measuredUnitsPerPointCache = fallback
            return fallback
        }
        let capUnits = CGFloat(mesh.bounds.extents.y)
        let measured = capUnits > 0 ? capUnits / capPoints : fallback
        measuredUnitsPerPointCache = measured
        return measured
    }

    @MainActor
    public static func build(spec: TextSpec, fontURL: URL? = nil) throws -> Result {
        let baseFont = resolveFont(family: spec.fontFamily, weight: spec.fontWeight,
                                   italic: spec.fontIsItalic,
                                   capHeightMetres: spec.fontSize,
                                   sourceURL: fontURL)
        let capRatio = CTFontGetCapHeight(baseFont) / max(CTFontGetSize(baseFont), 0.0001)
        let targetCapPoints = CGFloat(max(spec.fontSize, 0.0001)) / unitsPerPoint()
        let sized = capRatio > 0 ? targetCapPoints / capRatio : targetCapPoints
        let font = CTFontCreateCopyWithAttributes(baseFont, sized, nil, nil)
        let pointSize = CTFontGetSize(font)

        var attributed = AttributedString(spec.text)
        attributed.font = font
        if let tracking = spec.tracking {
            let scale = pointSize / CGFloat(max(spec.fontSize, 0.0001))
            attributed.kern = CGFloat(tracking) * scale
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(spec.alignmentX ?? .centre)
        if let leading = spec.leading {
            let scale = pointSize / CGFloat(max(spec.fontSize, 0.0001))
            paragraph.minimumLineHeight = CGFloat(leading) * scale
            paragraph.maximumLineHeight = CGFloat(leading) * scale
        }
        attributed.paragraphStyle = paragraph

        var textOptions = MeshResource.GenerateTextOptions()
        if let width = spec.maxWidth, width > 0.0001 {
            // Real height: a zero-height container CLIPS everything the
            // wrap produces, unlike the retired API's unbounded meaning.
            textOptions.containerFrame = CGRect(
                x: 0, y: 0,
                width: CGFloat(width) / unitsPerPoint(), height: 1_000_000)
        }

        var extrusion = MeshResource.ShapeExtrusionOptions()
        let depth = spec.extrusionDepth ?? defaultExtrusionDepth
        // Depth and bevel are metres; the extruder takes its own point-scale
        // units, so they convert through the same measured scale as the type.
        let unit = Float(unitsPerPoint())
        extrusion.extrusionMethod = .linear(depth: max(0, depth) / max(unit, 1e-9))
        extrusion.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 20)
        // The mirrored profile rule: an unknown id draws NO bevel.
        let profile = BevelProfiles.resolve(profileId: spec.bevelProfileId,
                                            segments: spec.bevelSegments)
        if let radius = spec.bevelRadius, radius > 0, profile != .unresolved {
            let ceiling = max(0.0005, depth > 0 ? depth / 2 : 0.002)
            extrusion.chamferRadius = min(radius, ceiling) / max(unit, 1e-9)
            switch spec.capFill ?? .both {
            case .front: extrusion.chamferMode = .front
            case .back:  extrusion.chamferMode = .back
            case .both, .none: extrusion.chamferMode = .both
            }
            if case .segments(let n) = profile {
                extrusion.chamferResolution = .uniformSegmentsPerSpan(segmentCount: n)
            }
        }
        var slotCount = 1
        if spec.slotMaterials?.isEmpty == false {
            extrusion.materialAssignment = .init(
                front: 0, back: 1, extrusion: 2, frontChamfer: 3, backChamfer: 4)
            slotCount = 5
        }

        let laidOut = try MeshResource(extruding: attributed,
                                       textOptions: textOptions,
                                       extrusionOptions: extrusion)
        // VERTICAL ANCHOR (FL-07 `alignmentY`) — the mirror of
        // `TitleGeometryContract.anchorOffsetY` / `translated`, baked into
        // the geometry exactly as the editors bake it. Absent ⇒ baseline,
        // the extruder's own layout, so older titles do not move.
        let offsetY = anchorOffsetY(alignment: spec.alignmentY, bounds: laidOut.bounds)
        let mesh = try translated(laidOut, by: SIMD3<Float>(0, offsetY, 0))
        return Result(mesh: mesh,
                      materials: materials(for: spec, slotCount: slotCount))
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.anchorOffsetY`.
    static func anchorOffsetY(alignment: TextAlignmentY?, bounds: BoundingBox) -> Float {
        switch alignment ?? .baseline {
        case .baseline: return 0
        case .top:      return -bounds.max.y
        case .centre:   return -(bounds.min.y + bounds.max.y) / 2
        case .bottom:   return -bounds.min.y
        }
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.translated`.
    @MainActor
    static func translated(_ mesh: MeshResource, by offset: SIMD3<Float>) throws -> MeshResource {
        guard simd_length(offset) > 1e-7 else { return mesh }
        var contents = mesh.contents
        var models = MeshModelCollection()
        for model in contents.models {
            var moved = model
            var parts = MeshPartCollection()
            for var part in model.parts {
                part.positions = MeshBuffers.Positions(part.positions.elements.map { $0 + offset })
                parts.insert(part)
            }
            moved.parts = parts
            models.insert(moved)
        }
        contents.models = models
        return try MeshResource.generate(from: contents)
    }

    static func nsAlignment(_ alignment: TextAlignmentX) -> NSTextAlignment {
        switch alignment {
        case .leading:   return .left
        case .centre:    return .center
        case .trailing:  return .right
        case .justified: return .justified
        case .natural:   return .natural
        }
    }

    @MainActor
    static func materials(for spec: TextSpec, slotCount: Int) -> [any Material] {
        func platform(_ material: MaterialSpec?) -> any Material {
            let tint = material?.baseColor ?? spec.color
            var out = PhysicallyBasedMaterial()
            out.baseColor = .init(tint: UIColor(
                red: CGFloat(tint.r), green: CGFloat(tint.g),
                blue: CGFloat(tint.b), alpha: CGFloat(tint.a)))
            out.metallic = .init(floatLiteral: material?.metallic ?? 0)
            out.roughness = .init(floatLiteral: material?.roughness ?? 0.3)
            if let emissive = material?.emissiveColor,
               (material?.emissiveIntensity ?? 0) > 0 {
                out.emissiveColor = .init(color: UIColor(
                    red: CGFloat(emissive.r), green: CGFloat(emissive.g),
                    blue: CGFloat(emissive.b), alpha: CGFloat(emissive.a)))
                out.emissiveIntensity = material?.emissiveIntensity ?? 0
            }
            if tint.a < 0.999 {
                out.blending = .transparent(opacity: .init(floatLiteral: tint.a))
            }
            return out
        }
        guard slotCount == 5, let slots = spec.slotMaterials else {
            return [platform(spec.material)]
        }
        let base = spec.material
        return [
            platform(slots.front ?? base),
            platform(slots.back ?? base),
            platform(slots.sides ?? base),
            platform(slots.frontBevel ?? base),
            platform(slots.backBevel ?? base),
        ]
    }
}

extension TitleMesh {
    /// Mirror of `MaestroKit.FontResolution.fontFromFile`.
    static func fontFromFile(_ url: URL, size: CGFloat) -> CTFont? {
        guard FileManager.default.fileExists(atPath: url.path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontCreateWithFontDescriptor(first, size, nil)
    }
}
