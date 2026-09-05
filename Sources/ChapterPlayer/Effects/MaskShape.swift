//
//  MaskShape.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/MaskShape.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import CoreGraphics
import ChapterScript

public struct MaskShape: Equatable, Sendable, Hashable {

    public enum Kind: String, Sendable, Equatable {
        case rectangle, ellipse, bezier
    }

    public var kind: Kind
    /// For rectangle/ellipse: two points, min and max corner. For a
    /// Bézier: the outline's vertices in order.
    public var points: [EffectPoint]
    public var closed: Bool

    public init(kind: Kind, points: [EffectPoint], closed: Bool = true) {
        self.kind = kind
        self.points = points
        self.closed = closed
    }

    /// THE GREAT DEFAULT: a centerd rectangle at 60% of the frame,
    /// already doing something.
    public static let defaultRectangle = MaskShape(
        kind: .rectangle,
        points: [EffectPoint(x: 0.2, y: 0.2), EffectPoint(x: 0.8, y: 0.8)])

    /// A Bézier with fewer than three points draws nothing — a legitimate
    /// waiting state, not an error.
    public var isDrawable: Bool {
        switch kind {
        case .rectangle, .ellipse: return points.count >= 2
        case .bezier: return points.count >= 3
        }
    }

    /// The path in a pixel space of the given size.
    public func path(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        guard isDrawable else { return path }
        func at(_ p: EffectPoint) -> CGPoint {
            CGPoint(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
        }
        switch kind {
        case .rectangle:
            let a = at(points[0]), b = at(points[1])
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .ellipse:
            let a = at(points[0]), b = at(points[1])
            path.addEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                       width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .bezier:
            path.move(to: at(points[0]))
            for point in points.dropFirst() { path.addLine(to: at(point)) }
            if closed { path.closeSubpath() }
        }
        return path
    }

    // MARK: - The wire shape (data in FL-09's container)

    public var effectValue: EffectValue {
        .raw(.object([
            "kind": .string(kind.rawValue),
            "closed": .bool(closed),
            "points": .array(points.map {
                .object(["x": .number(Double($0.x)), "y": .number(Double($0.y))])
            }),
        ]))
    }

    public init?(effectValue: EffectValue?) {
        guard case .raw(.object(let o))? = effectValue,
              case .string(let kindRaw)? = o["kind"],
              let kind = Kind(rawValue: kindRaw),
              case .array(let entries)? = o["points"] else { return nil }
        var parsed: [EffectPoint] = []
        for entry in entries {
            guard case .object(let point) = entry,
                  case .number(let x)? = point["x"],
                  case .number(let y)? = point["y"] else { return nil }
            parsed.append(EffectPoint(x: Float(x), y: Float(y)))
        }
        var closed = true
        if case .bool(let c)? = o["closed"] { closed = c }
        self.init(kind: kind, points: parsed, closed: closed)
    }
}
