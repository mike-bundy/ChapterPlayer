//
//  CaptionRunLayout.swift
//  ChapterPlayer
//
//  THE MIRROR of `MaestroKit.CaptionRunLayout` (FL-08). ChapterPlayer
//  cannot depend on MaestroKit, so how a caption's runs reach the geometry
//  is DUPLICATED here — the line limit, glyph-occurrence ↔ run matching by
//  pen position, recoloring by material slot, the outline halo — and
//  MaestroVision's `CaptionSeamTests` compare the two builds. Change one,
//  change both.
//

import Foundation
import CoreText
import CoreGraphics
import ChapterScript
import RealityKit

@MainActor
enum CaptionRunLayout {

    static func styleRuns(_ runs: [CaptionStyleRun]) -> [TitleMesh.StyleRun] {
        runs.compactMap { run in
            guard run.bold == true || run.italic == true else { return nil }
            return TitleMesh.StyleRun(start: run.start, length: run.length,
                                      bold: run.bold == true, italic: run.italic == true)
        }
    }

    static func clip(_ runs: [CaptionStyleRun], to text: String) -> [CaptionStyleRun] {
        let length = text.utf16.count
        return runs.compactMap { run in
            guard run.start >= 0, run.start < length, run.length > 0 else { return nil }
            var clipped = run
            clipped.length = min(run.length, length - run.start)
            return clipped
        }
    }

    // MARK: - The line limit

    struct Truncation: Equatable, Sendable {
        let text: String
        let removedLines: Int
    }

    static func truncate(spec: TextSpec, toLines limit: Int,
                         styleRuns: [TitleMesh.StyleRun] = []) -> Truncation {
        guard limit > 0, !spec.text.isEmpty,
              let frame = TitleMesh.containerFrame(for: spec)
        else { return Truncation(text: spec.text, removedLines: 0) }
        let font = TitleMesh.sizedFont(for: spec)
        let attributed = TitleMesh.attributed(spec: spec, font: font, styleRuns: styleRuns)
        let ns = NSAttributedString(attributed)
        let framesetter = CTFramesetterCreateWithAttributedString(ns)
        let path = CGPath(rect: frame, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(ctFrame) as! [CTLine]
        guard lines.count > limit else { return Truncation(text: spec.text, removedLines: 0) }
        let last = CTLineGetStringRange(lines[limit - 1])
        let end = min(last.location + last.length, ns.length)
        let cut = (ns.string as NSString).substring(to: end)
        return Truncation(text: cut.trimmingCharacters(in: .whitespacesAndNewlines),
                          removedLines: lines.count - limit)
    }

    // MARK: - Glyph occurrences → runs

    struct GlyphSpan: Equatable, Sendable {
        let instanceIDs: [String]
        let minX: Float
        let maxX: Float
        let baselineY: Float
        let lineIndex: Int
        let runIndex: Int?
    }

    private struct Occurrence {
        var instanceIDs: [String]
        let penX: Float
        let penY: Float
        var minX: Float
        var maxX: Float
    }

    static func glyphSpans(spec: TextSpec, runs: [CaptionStyleRun],
                           styleRuns: [TitleMesh.StyleRun],
                           mesh: MeshResource) -> [GlyphSpan] {
        let contents = mesh.contents
        var localX: [String: (Float, Float)] = [:]
        for model in contents.models {
            var lo: Float = .greatestFiniteMagnitude, hi: Float = -.greatestFiniteMagnitude
            for part in model.parts {
                for p in part.positions.elements { lo = min(lo, p.x); hi = max(hi, p.x) }
            }
            if lo <= hi { localX[model.id] = (lo, hi) }
        }
        var occurrences: [Occurrence] = []
        var indexByPen: [String: Int] = [:]
        for instance in contents.instances {
            let t = instance.transform.columns.3
            let key = "\(occurrenceKey(instance.id))|\(t.x)|\(t.y)"
            let (lo, hi) = localX[instance.model] ?? (0, 0)
            if let index = indexByPen[key] {
                occurrences[index].instanceIDs.append(instance.id)
                occurrences[index].minX = min(occurrences[index].minX, t.x + lo)
                occurrences[index].maxX = max(occurrences[index].maxX, t.x + hi)
            } else {
                indexByPen[key] = occurrences.count
                occurrences.append(Occurrence(instanceIDs: [instance.id], penX: t.x, penY: t.y,
                                              minX: t.x + lo, maxX: t.x + hi))
            }
        }
        guard !occurrences.isEmpty else { return [] }

        var meshLines: [[Occurrence]] = []
        for occurrence in occurrences.sorted(by: { $0.penY > $1.penY }) {
            if let last = meshLines.last, let ref = last.first,
               abs(ref.penY - occurrence.penY) < 1e-4 {
                meshLines[meshLines.count - 1].append(occurrence)
            } else {
                meshLines.append([occurrence])
            }
        }

        let font = TitleMesh.sizedFont(for: spec)
        let attributed = TitleMesh.attributed(spec: spec, font: font, styleRuns: styleRuns)
        let ns = NSAttributedString(attributed)
        let framesetter = CTFramesetterCreateWithAttributedString(ns)
        let frame = TitleMesh.containerFrame(for: spec)
            ?? CGRect(x: 0, y: 0, width: 1_000_000, height: TitleMesh.containerHeightPoints)
        let path = CGPath(rect: frame, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(ctFrame) as! [CTLine]
        let string = ns.string as NSString
        var ctLines: [[(relX: Float, index: Int)]] = []
        for line in lines {
            var glyphs: [(Float, Int)] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for g in 0..<count {
                    let index = indices[g]
                    guard index < string.length else { continue }
                    let scalar = string.character(at: index)
                    if let unicode = Unicode.Scalar(scalar),
                       CharacterSet.whitespacesAndNewlines.contains(unicode) { continue }
                    glyphs.append((Float(positions[g].x), index))
                }
            }
            let first = glyphs.map(\.0).min() ?? 0
            ctLines.append(glyphs.map { (relX: $0.0 - first, index: $0.1) })
        }

        let unit = Float(TitleMesh.unitsPerPoint())
        var spans: [GlyphSpan] = []
        for (lineIndex, meshLine) in meshLines.enumerated() {
            let glyphs = lineIndex < ctLines.count ? ctLines[lineIndex] : []
            let firstPen = meshLine.map(\.penX).min() ?? 0
            for occurrence in meshLine.sorted(by: { $0.penX < $1.penX }) {
                let relPoints = (occurrence.penX - firstPen) / max(unit, 1e-9)
                let owner = glyphs.min { abs($0.relX - relPoints) < abs($1.relX - relPoints) }
                let runIndex = owner.flatMap { glyph in
                    runs.firstIndex { glyph.index >= $0.start && glyph.index < $0.start + $0.length }
                }
                spans.append(GlyphSpan(instanceIDs: occurrence.instanceIDs,
                                       minX: occurrence.minX, maxX: occurrence.maxX,
                                       baselineY: occurrence.penY,
                                       lineIndex: lineIndex, runIndex: runIndex))
            }
        }
        return spans
    }

    static func occurrenceKey(_ instanceID: String) -> String {
        guard let dash = instanceID.lastIndex(of: "-") else { return instanceID }
        let suffix = instanceID[dash...]
        if let open = instanceID[..<dash].lastIndex(of: "["),
           instanceID[..<dash].hasSuffix("]") {
            return String(instanceID[open..<dash]) + suffix
        }
        return String(suffix)
    }

    // MARK: - Recoloring by slot

    static func recolored(_ mesh: MeshResource, spans: [GlyphSpan],
                           slotByRun: [Int: UInt32]) throws -> MeshResource {
        var slotByInstance: [String: UInt32] = [:]
        for span in spans {
            guard let run = span.runIndex, let slot = slotByRun[run] else { continue }
            for id in span.instanceIDs { slotByInstance[id] = slot }
        }
        guard !slotByInstance.isEmpty else { return mesh }
        var contents = mesh.contents
        var models = contents.models
        var instances = MeshInstanceCollection()
        for instance in contents.instances {
            guard let slot = slotByInstance[instance.id],
                  let base = models[instance.model] else {
                instances.insert(instance)
                continue
            }
            let variantID = "\(instance.model)#slot\(slot)"
            if models[variantID] == nil {
                var variant = base
                variant.id = variantID
                var parts = MeshPartCollection()
                for var part in base.parts {
                    part.materialIndex = Int(slot)
                    parts.insert(part)
                }
                variant.parts = parts
                models.insert(variant)
            }
            instances.insert(MeshResource.Instance(id: instance.id, model: variantID,
                                                   at: instance.transform))
        }
        contents.models = models
        contents.instances = instances
        return try MeshResource.generate(from: contents)
    }

    // MARK: - The outline halo

    static func outlined(_ mesh: MeshResource, growBy factor: Float) throws -> MeshResource {
        guard factor > 1.0001 else { return mesh }
        var contents = mesh.contents
        var models = MeshModelCollection()
        for model in contents.models {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for part in model.parts {
                for p in part.positions.elements { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            }
            guard lo.x <= hi.x else { models.insert(model); continue }
            let center = SIMD3<Float>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0)
            var grown = model
            var parts = MeshPartCollection()
            for var part in model.parts {
                part.positions = MeshBuffers.Positions(part.positions.elements.map {
                    SIMD3<Float>(center.x + ($0.x - center.x) * factor,
                                 center.y + ($0.y - center.y) * factor,
                                 $0.z)
                })
                parts.insert(part)
            }
            grown.parts = parts
            models.insert(grown)
        }
        contents.models = models
        return try MeshResource.generate(from: contents)
    }
}
