//
//  VectorMesh.swift
//  ChapterPlayer
//
//  THE MIRRORED VECTOR CONTRACT (FL-22). ChapterPlayer cannot depend on
//  MaestroKit, so `MaestroKit.SVGParser` + `VectorGeometry`'s recipe is
//  DUPLICATED here — same parser, same per-path fill-rule normalization,
//  same extrusion options, same material mapping — exactly as `TitleMesh`
//  mirrors `TitleGeometry`. Change one, change both; the seam test in
//  MaestroVision compares the builds.
//
//  A `.vector` Object is BUILT here, never mapped to `.custom` — a kind
//  this build knows must be built.
//

import Foundation
import CoreGraphics
import RealityKit
import UIKit
import SwiftUI
import ChapterScript

public enum VectorMesh {

    public static let defaultPhysicalWidth: Float = 0.5

    public struct Result {
        public let mesh: MeshResource
        public let materials: [any RealityKit.Material]
    }

    // MARK: - Parsed shape (the mirror of MaestroKit.VectorPath)

    struct ParsedPath {
        enum Element {
            case move(CGPoint)
            case line(CGPoint)
            case quad(control: CGPoint, to: CGPoint)
            case cubic(control1: CGPoint, control2: CGPoint, to: CGPoint)
            case close
        }
        enum FillRule: String { case nonzero, evenodd }
        var elements: [Element]
        var fillRule: FillRule
    }

    struct ParseOutput {
        var paths: [ParsedPath] = []
        var viewBox: CGRect?
    }

    // MARK: - Build

    @MainActor
    public static func build(spec: VectorSpec, svgData: Data) throws -> Result? {
        let parsed = parse(data: svgData)
        guard !parsed.paths.isEmpty,
              let combined = combinedPath(parsed, physicalWidth: spec.physicalWidth)
        else { return nil }

        let depth = spec.extrusionDepth ?? 0
        let capFill = spec.capFill ?? .both
        var extrusion = MeshResource.ShapeExtrusionOptions()
        extrusion.extrusionMethod = .linear(depth: max(0, depth))
        extrusion.boundaryResolution = .uniformSegmentsPerSpan(segmentCount: 20)

        if let radius = spec.bevelRadius, radius > 0 {
            let ceiling = max(0.0005, depth > 0 ? depth / 2 : 0.002)
            extrusion.chamferRadius = min(radius, ceiling)
            switch capFill {
            case .front: extrusion.chamferMode = .front
            case .back:  extrusion.chamferMode = .back
            case .both, .none: extrusion.chamferMode = .both
            }
        }

        var slotCount = 1
        if spec.slotMaterials?.isEmpty == false {
            extrusion.materialAssignment = .init(
                front: 0, back: 1, extrusion: 2, frontChamfer: 3, backChamfer: 4)
            slotCount = 5
        }

        let mesh = try MeshResource(extruding: combined,
                                    extrusionOptions: extrusion)
        return Result(mesh: mesh, materials: materials(for: spec, slotCount: slotCount))
    }

    // MARK: - Materials (the same recipe as a Title's slots)

    static func materials(for spec: VectorSpec, slotCount: Int) -> [any RealityKit.Material] {
        func platform(_ material: MaterialSpec?) -> any RealityKit.Material {
            let tint = material?.baseColor ?? ColorRGBA(r: 1, g: 1, b: 1, a: 1)
            var out = PhysicallyBasedMaterial()
            out.baseColor = .init(tint: UIColor(
                red: CGFloat(tint.r), green: CGFloat(tint.g),
                blue: CGFloat(tint.b), alpha: CGFloat(tint.a)))
            out.metallic = .init(floatLiteral: material?.metallic ?? 0)
            out.roughness = .init(floatLiteral: material?.roughness ?? 0.4)
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
            return [platform(nil)]
        }
        return [
            platform(slots.front), platform(slots.back), platform(slots.sides),
            platform(slots.frontBevel), platform(slots.backBevel),
        ]
    }

    // MARK: - Contours → Path (fill rule honoured per path)

    static func combinedPath(_ parsed: ParseOutput,
                             physicalWidth: Float?) -> SwiftUI.Path? {
        let merged = CGMutablePath()
        for parsedPath in parsed.paths {
            let cg = CGMutablePath()
            for element in parsedPath.elements {
                switch element {
                case .move(let p): cg.move(to: p)
                case .line(let p): cg.addLine(to: p)
                case .quad(let c, let p): cg.addQuadCurve(to: p, control: c)
                case .cubic(let c1, let c2, let p):
                    cg.addCurve(to: p, control1: c1, control2: c2)
                case .close: cg.closeSubpath()
                }
            }
            merged.addPath(cg.normalized(using: parsedPath.fillRule == .evenodd
                                         ? .evenOdd : .winding))
        }
        let bounds = parsed.viewBox ?? merged.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let width = CGFloat(physicalWidth ?? defaultPhysicalWidth)
        let scale = width / bounds.width
        var transform = CGAffineTransform(scaleX: scale, y: -scale)
            .translatedBy(x: -bounds.minX, y: -bounds.maxY)
        guard let placed = merged.mutableCopy(using: &transform) else { return nil }
        return SwiftUI.Path(placed)
    }

    // MARK: - The parser (mirror of MaestroKit.SVGParser, skips uncounted —
    // the REPORT is an authoring concern; the runtime just draws)

    static func parse(data: Data) -> ParseOutput {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return ParseOutput(paths: delegate.paths, viewBox: delegate.viewBox)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var paths: [ParsedPath] = []
        var viewBox: CGRect?
        private var stack: [(transform: CGAffineTransform, fillRule: ParsedPath.FillRule)] =
            [(.identity, .nonzero)]
        private var suppressedDepth = 0
        private static let suppressed: Set<String> = [
            "filter", "mask", "clipPath", "pattern", "marker",
            "linearGradient", "radialGradient", "symbol", "style", "script",
            "text", "defs"
        ]

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if suppressedDepth > 0 { suppressedDepth += 1; return }
            if Self.suppressed.contains(local) { suppressedDepth = 1; return }

            let inherited = stack[stack.count - 1]
            let transform = (attrs["transform"].map(Self.parseTransform) ?? .identity)
                .concatenating(inherited.transform)
            let fillRule = Self.fillRule(from: attrs) ?? inherited.fillRule

            switch local {
            case "svg":
                if viewBox == nil, let box = attrs["viewBox"] {
                    let n = numbers(in: box)
                    if n.count == 4 {
                        viewBox = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
                    }
                }
                stack.append((transform, fillRule))
            case "g":
                stack.append((transform, fillRule))
            case "path":
                if let d = attrs["d"], let elements = PathData.parse(d) {
                    append(elements, transform: transform, fillRule: fillRule)
                }
            case "rect":
                let x = number(attrs["x"]) ?? 0, y = number(attrs["y"]) ?? 0
                guard let w = number(attrs["width"]), let h = number(attrs["height"]),
                      w > 0, h > 0 else { return }
                append([.move(CGPoint(x: x, y: y)),
                        .line(CGPoint(x: x + w, y: y)),
                        .line(CGPoint(x: x + w, y: y + h)),
                        .line(CGPoint(x: x, y: y + h)),
                        .close], transform: transform, fillRule: fillRule)
            case "circle", "ellipse":
                let cx = number(attrs["cx"]) ?? 0, cy = number(attrs["cy"]) ?? 0
                let rx = number(attrs["rx"]) ?? number(attrs["r"]) ?? 0
                let ry = number(attrs["ry"]) ?? number(attrs["r"]) ?? 0
                guard rx > 0, ry > 0 else { return }
                let k = 0.5522847498307936
                let kx = rx * k, ky = ry * k
                append([
                    .move(CGPoint(x: cx + rx, y: cy)),
                    .cubic(control1: CGPoint(x: cx + rx, y: cy + ky),
                           control2: CGPoint(x: cx + kx, y: cy + ry),
                           to: CGPoint(x: cx, y: cy + ry)),
                    .cubic(control1: CGPoint(x: cx - kx, y: cy + ry),
                           control2: CGPoint(x: cx - rx, y: cy + ky),
                           to: CGPoint(x: cx - rx, y: cy)),
                    .cubic(control1: CGPoint(x: cx - rx, y: cy - ky),
                           control2: CGPoint(x: cx - kx, y: cy - ry),
                           to: CGPoint(x: cx, y: cy - ry)),
                    .cubic(control1: CGPoint(x: cx + kx, y: cy - ry),
                           control2: CGPoint(x: cx + rx, y: cy - ky),
                           to: CGPoint(x: cx + rx, y: cy)),
                    .close,
                ], transform: transform, fillRule: fillRule)
            case "line":
                append([.move(CGPoint(x: number(attrs["x1"]) ?? 0, y: number(attrs["y1"]) ?? 0)),
                        .line(CGPoint(x: number(attrs["x2"]) ?? 0, y: number(attrs["y2"]) ?? 0))],
                       transform: transform, fillRule: fillRule)
            case "polyline", "polygon":
                let n = numbers(in: attrs["points"] ?? "")
                guard n.count >= 4 else { return }
                var e: [ParsedPath.Element] = [.move(CGPoint(x: n[0], y: n[1]))]
                var i = 2
                while i + 1 < n.count {
                    e.append(.line(CGPoint(x: n[i], y: n[i + 1])))
                    i += 2
                }
                if local == "polygon" { e.append(.close) }
                append(e, transform: transform, fillRule: fillRule)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if suppressedDepth > 0 { suppressedDepth -= 1; return }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "g" || local == "svg", stack.count > 1 {
                stack.removeLast()
            }
        }

        private func append(_ elements: [ParsedPath.Element],
                            transform: CGAffineTransform,
                            fillRule: ParsedPath.FillRule) {
            guard !elements.isEmpty else { return }
            let transformed: [ParsedPath.Element] = transform.isIdentity
                ? elements
                : elements.map { element in
                    switch element {
                    case .move(let p): return .move(p.applying(transform))
                    case .line(let p): return .line(p.applying(transform))
                    case .quad(let c, let p):
                        return .quad(control: c.applying(transform), to: p.applying(transform))
                    case .cubic(let c1, let c2, let p):
                        return .cubic(control1: c1.applying(transform),
                                      control2: c2.applying(transform),
                                      to: p.applying(transform))
                    case .close: return .close
                    }
                }
            paths.append(ParsedPath(elements: transformed, fillRule: fillRule))
        }

        static func fillRule(from attrs: [String: String]) -> ParsedPath.FillRule? {
            if let raw = attrs["fill-rule"] ?? attrs["clip-rule"],
               let rule = ParsedPath.FillRule(rawValue: raw.trimmingCharacters(in: .whitespaces)) {
                return rule
            }
            if let style = attrs["style"] {
                for declaration in style.split(separator: ";") {
                    let parts = declaration.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    if key == "fill-rule" || key == "clip-rule",
                       let rule = ParsedPath.FillRule(
                        rawValue: parts[1].trimmingCharacters(in: .whitespaces)) {
                        return rule
                    }
                }
            }
            return nil
        }

        static func parseTransform(_ raw: String) -> CGAffineTransform {
            var out = CGAffineTransform.identity
            let scanner = Scanner(string: raw)
            while let name = scanner.scanUpToString("(") {
                _ = scanner.scanString("(")
                guard let inside = scanner.scanUpToString(")") else { break }
                _ = scanner.scanString(")")
                let n = numbers(in: inside)
                let t: CGAffineTransform
                switch name.trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t")) {
                case "matrix" where n.count == 6:
                    t = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                case "translate" where n.count >= 1:
                    t = CGAffineTransform(translationX: n[0], y: n.count > 1 ? n[1] : 0)
                case "scale" where n.count >= 1:
                    t = CGAffineTransform(scaleX: n[0], y: n.count > 1 ? n[1] : n[0])
                case "rotate" where n.count == 1:
                    t = CGAffineTransform(rotationAngle: n[0] * .pi / 180)
                case "rotate" where n.count == 3:
                    t = CGAffineTransform(translationX: n[1], y: n[2])
                        .rotated(by: n[0] * .pi / 180)
                        .translatedBy(x: -n[1], y: -n[2])
                case "skewX" where n.count == 1:
                    t = CGAffineTransform(a: 1, b: 0, c: tan(n[0] * .pi / 180), d: 1, tx: 0, ty: 0)
                case "skewY" where n.count == 1:
                    t = CGAffineTransform(a: 1, b: tan(n[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
                default:
                    t = .identity
                }
                out = t.concatenating(out)
            }
            return out
        }
    }

    // MARK: The `d` grammar (mirror)

    enum PathData {
        static func parse(_ d: String) -> [ParsedPath.Element]? {
            var out: [ParsedPath.Element] = []
            var current = CGPoint.zero
            var subpathStart = CGPoint.zero
            var lastControl: CGPoint?
            var lastCommand: Character = " "
            let scanner = Scanner(string: d)
            scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\r\t")

            // A drawable path has at least one move; a string that only
            // yielded closes (a bare Z before garbage) is malformed, not a
            // shape.
            func finished(_ e: [ParsedPath.Element]) -> [ParsedPath.Element]? {
                e.contains(where: { if case .move = $0 { return true }; return false })
                    ? e : nil
            }
            func num() -> CGFloat? { scanner.scanDouble().map { CGFloat($0) } }
            func point(relative: Bool) -> CGPoint? {
                guard let x = num(), let y = num() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y)
                                : CGPoint(x: x, y: y)
            }

            var command: Character? = nil
            while !scanner.isAtEnd {
                let loopStart = scanner.currentIndex
                let before = scanner.currentIndex
                if let c = scanner.scanCharacter(), "MmLlHhVvCcSsQqTtAaZz".contains(c) {
                    command = c
                } else {
                    scanner.currentIndex = before
                    if command == "M" { command = "L" }
                    if command == "m" { command = "l" }
                }
                guard let c = command else { return finished(out) }
                let rel = c.isLowercase
                switch Character(c.uppercased()) {
                case "M":
                    guard let p = point(relative: rel) else { return finished(out) }
                    out.append(.move(p)); current = p; subpathStart = p
                case "L":
                    guard let p = point(relative: rel) else { return finished(out) }
                    out.append(.line(p)); current = p
                case "H":
                    guard let x = num() else { return finished(out) }
                    let p = CGPoint(x: rel ? current.x + x : x, y: current.y)
                    out.append(.line(p)); current = p
                case "V":
                    guard let y = num() else { return finished(out) }
                    let p = CGPoint(x: current.x, y: rel ? current.y + y : y)
                    out.append(.line(p)); current = p
                case "C":
                    guard let c1 = point(relative: rel), let c2 = point(relative: rel),
                          let p = point(relative: rel) else { return finished(out) }
                    out.append(.cubic(control1: c1, control2: c2, to: p))
                    lastControl = c2; current = p
                case "S":
                    guard let c2 = point(relative: rel),
                          let p = point(relative: rel) else { return finished(out) }
                    let c1: CGPoint
                    if "CcSs".contains(lastCommand), let last = lastControl {
                        c1 = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                    } else { c1 = current }
                    out.append(.cubic(control1: c1, control2: c2, to: p))
                    lastControl = c2; current = p
                case "Q":
                    guard let cq = point(relative: rel),
                          let p = point(relative: rel) else { return finished(out) }
                    out.append(.quad(control: cq, to: p))
                    lastControl = cq; current = p
                case "T":
                    guard let p = point(relative: rel) else { return finished(out) }
                    let cq: CGPoint
                    if "QqTt".contains(lastCommand), let last = lastControl {
                        cq = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                    } else { cq = current }
                    out.append(.quad(control: cq, to: p))
                    lastControl = cq; current = p
                case "A":
                    guard let rx = num(), let ry = num(), let rot = num(),
                          let largeArc = num(), let sweep = num(),
                          let p = point(relative: rel) else { return finished(out) }
                    out.append(contentsOf: arcToCubics(
                        from: current, to: p, rx: rx, ry: ry,
                        xAxisRotationDegrees: rot,
                        largeArc: largeArc != 0, sweep: sweep != 0))
                    current = p
                case "Z":
                    out.append(.close); current = subpathStart
                default:
                    return finished(out)
                }
                if !"CcSsQqTt".contains(c) { lastControl = nil }
                lastCommand = c
                // NO PROGRESS MEANS STOP: a repeated command that consumes
                // nothing (a bare Z before garbage) would otherwise loop
                // forever appending closes. Keep what parsed; skip the rest.
                if scanner.currentIndex == loopStart {
                    return finished(out)
                }
            }
            return finished(out)
        }

        static func arcToCubics(from start: CGPoint, to end: CGPoint,
                                rx rawRx: CGFloat, ry rawRy: CGFloat,
                                xAxisRotationDegrees: CGFloat,
                                largeArc: Bool, sweep: Bool) -> [ParsedPath.Element] {
            var rx = abs(rawRx), ry = abs(rawRy)
            if rx < 1e-9 || ry < 1e-9 || start == end {
                return [.line(end)]
            }
            let phi = xAxisRotationDegrees * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
            let x1p = cosPhi * dx + sinPhi * dy
            let y1p = -sinPhi * dx + cosPhi * dy
            let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
            if lambda > 1 {
                let s = sqrt(lambda)
                rx *= s; ry *= s
            }
            let sign: CGFloat = largeArc != sweep ? 1 : -1
            let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let coefficient = sign * sqrt(max(0, numerator / max(denominator, 1e-12)))
            let cxp = coefficient * rx * y1p / ry
            let cyp = -coefficient * ry * x1p / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2
            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
                var a = acos(min(1, max(-1, dot / max(len, 1e-12))))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
            var deltaTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                                   (-x1p - cxp) / rx, (-y1p - cyp) / ry)
            if !sweep, deltaTheta > 0 { deltaTheta -= 2 * .pi }
            if sweep, deltaTheta < 0 { deltaTheta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
            let delta = deltaTheta / CGFloat(segments)
            let t = 4 / 3 * tan(delta / 4)
            var out: [ParsedPath.Element] = []
            var theta = theta1
            for _ in 0..<segments {
                let cos1 = cos(theta), sin1 = sin(theta)
                let theta2 = theta + delta
                let cos2 = cos(theta2), sin2 = sin(theta2)
                func onEllipse(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                    CGPoint(x: cx + rx * cosPhi * c - ry * sinPhi * s,
                            y: cy + rx * sinPhi * c + ry * cosPhi * s)
                }
                func derivative(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                    CGPoint(x: -rx * cosPhi * s - ry * sinPhi * c,
                            y: -rx * sinPhi * s + ry * cosPhi * c)
                }
                let p1 = onEllipse(cos1, sin1), p2 = onEllipse(cos2, sin2)
                let d1 = derivative(cos1, sin1), d2 = derivative(cos2, sin2)
                out.append(.cubic(
                    control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                    control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y),
                    to: p2))
                theta = theta2
            }
            return out
        }
    }
}

// MARK: - Shared numeric scanning (mirror)

private func number(_ raw: String?) -> CGFloat? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let digits = trimmed.prefix { "0123456789.+-eE".contains($0) }
    return Double(digits).map { CGFloat($0) }
}

private func numbers(in raw: String) -> [CGFloat] {
    var out: [CGFloat] = []
    let scanner = Scanner(string: raw)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\r\t")
    while let value = scanner.scanDouble() {
        out.append(CGFloat(value))
    }
    return out
}
