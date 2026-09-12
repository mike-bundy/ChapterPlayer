//
//  TitleMesh.swift
//  ChapterPlayer
//
//  THE MIRRORED TITLE CONTRACT (FL-07). ChapterPlayer cannot depend on
//  MaestroKit, so `MaestroKit.TitleGeometry`'s recipe is DUPLICATED here —
//  same font resolution (cap-height meters), same attributed string, same
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

    /// Mirror of `MaestroKit.TitleGeometryContract.bevelCapHeightFraction`
    /// / `bevelCeiling`, and the seam test holds the two together.
    ///
    /// A chamfer is carved out of the LETTERS, not out of the slab:
    /// RealityKit walks a straight skeleton inward from each glyph outline,
    /// and a radius that reaches the middle of a stem collapses the
    /// wavefront and ABORTS THE PROCESS from C++ — uncatchable here as it
    /// is in the editor. The old ceiling was `depth / 2`, which knows
    /// nothing about how thick the letters are; this one is the smaller of
    /// that slab limit and a measured fraction of the cap height (the
    /// thinnest face measured, Didot, aborts at 0.94%).
    public static let bevelCapHeightFraction: Float = 0.006

    public static func bevelCeiling(depth: Float, fontSize: Float) -> Float {
        let slab = depth > 0 ? depth / 2 : 0.002
        let glyphs = bevelCapHeightFraction * max(fontSize, 0.0001)
        return min(slab, glyphs)
    }

    public struct Result {
        public let mesh: MeshResource
        public let materials: [any Material]
    }

    /// Mirror of `MaestroKit.TitleGeometry.StyleRun`: a per-range face
    /// request in UTF-16 offsets (FL-08 caption runs).
    public struct StyleRun: Equatable, Hashable, Sendable {
        public var start: Int
        public var length: Int
        public var bold: Bool
        public var italic: Bool

        public init(start: Int, length: Int, bold: Bool = false, italic: Bool = false) {
            self.start = start
            self.length = length
            self.bold = bold
            self.italic = italic
        }
    }

    /// Cap-height-meters font resolution — the mirror of
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
        let meters = CGFloat(max(capHeightMetres, 0.0001))
        let pointSize = capAtProbe > 0 ? meters * probeSize / capAtProbe : meters
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

    /// Mirror of `MaestroKit.TitleGeometryContract.sizedFont`: the face at
    /// the size that makes `spec.fontSize` meters of cap height.
    @MainActor
    static func sizedFont(for spec: TextSpec, fontURL: URL? = nil) -> CTFont {
        let baseFont = resolveFont(family: spec.fontFamily, weight: spec.fontWeight,
                                   italic: spec.fontIsItalic,
                                   capHeightMetres: spec.fontSize,
                                   sourceURL: fontURL)
        let capRatio = CTFontGetCapHeight(baseFont) / max(CTFontGetSize(baseFont), 0.0001)
        let targetCapPoints = CGFloat(max(spec.fontSize, 0.0001)) / unitsPerPoint()
        let sized = capRatio > 0 ? targetCapPoints / capRatio : targetCapPoints
        return CTFontCreateCopyWithAttributes(baseFont, sized, nil, nil)
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.attributed` — ONE recipe,
    /// with a styled run as a per-range font the extruder shapes.
    static func attributed(spec: TextSpec, font: CTFont,
                           styleRuns: [StyleRun] = []) -> AttributedString {
        let pointSize = CTFontGetSize(font)
        var attributed = AttributedString(spec.text)
        attributed.font = font
        if let tracking = spec.tracking {
            let scale = pointSize / CGFloat(max(spec.fontSize, 0.0001))
            attributed.kern = CGFloat(tracking) * scale
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(spec.alignmentX ?? .center)
        if let leading = spec.leading {
            let scale = pointSize / CGFloat(max(spec.fontSize, 0.0001))
            paragraph.minimumLineHeight = CGFloat(leading) * scale
            paragraph.maximumLineHeight = CGFloat(leading) * scale
        }
        attributed.paragraphStyle = paragraph
        if !styleRuns.isEmpty {
            let text = String(attributed.characters)
            let utf16 = text.utf16
            for run in styleRuns where run.length > 0 && (run.bold || run.italic) {
                guard let lower = utf16.index(utf16.startIndex, offsetBy: run.start,
                                              limitedBy: utf16.endIndex),
                      let upper = utf16.index(lower, offsetBy: run.length,
                                              limitedBy: utf16.endIndex),
                      lower < upper,
                      let range = Range(lower..<upper, in: attributed)
                else { continue }
                attributed[range].font = traitFont(font, bold: run.bold, italic: run.italic) as UIFont
            }
        }
        return attributed
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.traitFont`.
    static func traitFont(_ base: CTFont, bold: Bool, italic: Bool) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        if let styled = CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) {
            return styled
        }
        var descriptorTraits: [CFString: Any] = [:]
        if bold { descriptorTraits[kCTFontWeightTrait] = 0.4 }
        if italic { descriptorTraits[kCTFontSlantTrait] = 0.2 }
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: descriptorTraits] as CFDictionary)
        let attempt = CTFontCreateCopyWithAttributes(base, 0, nil, descriptor)
        let got = CTFontGetSymbolicTraits(attempt)
        let wantedBold = !bold || got.contains(.traitBold)
        let wantedItalic = !italic || got.contains(.traitItalic)
        return (wantedBold && wantedItalic) ? attempt : base
    }

    static let containerHeightPoints: CGFloat = 1_000_000

    /// Mirror of `MaestroKit.TitleGeometryContract.containerFrame`.
    @MainActor
    static func containerFrame(for spec: TextSpec) -> CGRect? {
        guard let width = spec.maxWidth, width > 0.0001 else { return nil }
        // Real height: a zero-height container CLIPS everything the
        // wrap produces, unlike the retired API's unbounded meaning.
        return CGRect(x: 0, y: 0,
                      width: CGFloat(width) / unitsPerPoint(),
                      height: containerHeightPoints)
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.framedLayoutShiftPoints`:
    /// how far (points) a framed layout comes down from the container's
    /// top to sit where a frameless line does.
    static func framedLayoutShiftPoints(attributed: AttributedString, frame: CGRect?) -> CGFloat {
        guard let frame else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(attributed))
        let path = CGPath(rect: frame, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(ctFrame) as! [CTLine]
        guard let first = lines.first else { return 0 }
        var origin = CGPoint.zero
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 1), &origin)
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(first, nil, &descent, nil)
        return origin.y - descent
    }

    @MainActor
    public static func build(spec: TextSpec, fontURL: URL? = nil,
                             styleRuns: [StyleRun] = []) throws -> Result {
        let font = sizedFont(for: spec, fontURL: fontURL)
        let attributed = attributed(spec: spec, font: font, styleRuns: styleRuns)

        var textOptions = MeshResource.GenerateTextOptions()
        let container = containerFrame(for: spec)
        if let container { textOptions.containerFrame = container }

        var extrusion = MeshResource.ShapeExtrusionOptions()
        let depth = spec.extrusionDepth ?? defaultExtrusionDepth
        // Depth and bevel are meters; the extruder takes its own point-scale
        // units, so they convert through the same measured scale as the type.
        let unit = Float(unitsPerPoint())
        extrusion.extrusionMethod = .linear(depth: max(0, depth) / max(unit, 1e-9))
        extrusion.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 20)
        // The mirrored profile rule: an unknown id draws NO bevel.
        let profile = BevelProfiles.resolve(profileId: spec.bevelProfileId,
                                            segments: spec.bevelSegments)
        if let radius = spec.bevelRadius, radius > 0, profile != .unresolved {
            extrusion.chamferRadius = min(radius, bevelCeiling(depth: depth,
                                                              fontSize: spec.fontSize))
                / max(unit, 1e-9)
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
        // A WRAPPED block comes down from the container's top to where a
        // frameless line sits — the editors' wrapped-layout rule.
        let frameShift = -Float(framedLayoutShiftPoints(attributed: attributed,
                                                        frame: container) * unitsPerPoint())
        let settled = BoundingBox(min: laidOut.bounds.min + SIMD3<Float>(0, frameShift, 0),
                                  max: laidOut.bounds.max + SIMD3<Float>(0, frameShift, 0))
        // VERTICAL ANCHOR (FL-07 `alignmentY`) — the mirror of
        // `TitleGeometryContract.anchorOffsetY` / `translated`, baked into
        // the geometry exactly as the editors bake it. Absent ⇒ baseline,
        // the extruder's own layout, so older titles do not move.
        let offsetY = anchorOffsetY(alignment: spec.alignmentY, bounds: settled)
        let mesh = try translated(laidOut, by: SIMD3<Float>(0, frameShift + offsetY, 0))
        return Result(mesh: mesh,
                      materials: materials(for: spec, slotCount: slotCount))
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.anchorOffsetY`.
    static func anchorOffsetY(alignment: TextAlignmentY?, bounds: BoundingBox) -> Float {
        switch alignment ?? .baseline {
        case .baseline: return 0
        case .top:      return -bounds.max.y
        case .center:   return -(bounds.min.y + bounds.max.y) / 2
        case .bottom:   return -bounds.min.y
        }
    }

    /// Mirror of `MaestroKit.TitleGeometryContract.translated`: instances
    /// (pen positions) move when the mesh has them, vertices otherwise.
    @MainActor
    static func translated(_ mesh: MeshResource, by offset: SIMD3<Float>) throws -> MeshResource {
        guard simd_length(offset) > 1e-7 else { return mesh }
        var contents = mesh.contents
        if contents.instances.count > 0 {
            var instances = MeshInstanceCollection()
            for instance in contents.instances {
                var transform = instance.transform
                transform.columns.3 += SIMD4<Float>(offset, 0)
                instances.insert(MeshResource.Instance(id: instance.id, model: instance.model,
                                                       at: transform))
            }
            contents.instances = instances
            return try MeshResource.generate(from: contents)
        }
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
        case .center:    return .center
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
