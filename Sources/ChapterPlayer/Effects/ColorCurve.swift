//
//  ColorCurve.swift
//  ChapterPlayer
//
//  MIRROR of MaestroKit/Sources/MaestroKit/ColorCurve.swift (FL-09 … FL-13 player
//  parity). ChapterPlayer cannot depend on MaestroKit, so the one effect
//  evaluator is DUPLICATED here verbatim below this header, and
//  MaestroVision's EffectSeamTests render the same stack through both and
//  compare the pixels. Change one, change both.
//
import Foundation
import ChapterScript

public struct ColorCurve: Equatable, Sendable {

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// Sorted by x, deduplicated, clamped to 0…1.
    public private(set) var points: [Point]

    public static let identity = ColorCurve(points: [Point(x: 0, y: 0),
                                                     Point(x: 1, y: 1)])!

    /// Nil for fewer than two distinct points — refused at the boundary.
    public init?(points: [Point]) {
        var sorted = points
            .map { Point(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
            .sorted { $0.x < $1.x }
        var deduped: [Point] = []
        for point in sorted where deduped.last.map({ point.x - $0.x > 0.0005 }) ?? true {
            deduped.append(point)
        }
        sorted = deduped
        guard sorted.count >= 2 else { return nil }
        self.points = sorted
    }

    public var isIdentity: Bool { self == .identity }

    // MARK: - Evaluation (monotone cubic — Fritsch–Carlson tangents)

    /// y at x, monotone between the authored points: no overshoot, ever.
    public func value(at x: Double) -> Double {
        let n = points.count
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }

        // Segment secants and F-C tangents.
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slopes[i] = dx > 0 ? (points[i + 1].y - points[i].y) / dx : 0
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            if slopes[i - 1] * slopes[i] <= 0 {
                tangents[i] = 0     // a local extremum stays an extremum
            } else {
                // Harmonic mean keeps the segment monotone.
                let w1 = 2 * (points[i + 1].x - points[i].x)
                    + (points[i].x - points[i - 1].x)
                let w2 = (points[i + 1].x - points[i].x)
                    + 2 * (points[i].x - points[i - 1].x)
                tangents[i] = (w1 + w2) / (w1 / slopes[i - 1] + w2 / slopes[i])
            }
        }

        // The segment holding x.
        var segment = 0
        for i in 0..<(n - 1) where points[i].x <= x { segment = i }
        let h = points[segment + 1].x - points[segment].x
        guard h > 0 else { return points[segment].y }
        let t = (x - points[segment].x) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * points[segment].y
            + h10 * h * tangents[segment]
            + h01 * points[segment + 1].y
            + h11 * h * tangents[segment + 1]
    }

    /// A sampled 1D table for GPU application (Core Image tone curve or a
    /// cube dimension).
    public func sampled(count: Int = 256) -> [Double] {
        (0..<count).map { value(at: Double($0) / Double(count - 1)) }
    }

    // MARK: - The wire shape (data in FL-09's container)

    public var effectValue: EffectValue {
        .raw(.array(points.map {
            .object(["x": .number($0.x), "y": .number($0.y)])
        }))
    }

    public init?(effectValue: EffectValue?) {
        guard case .raw(.array(let entries))? = effectValue else { return nil }
        var parsed: [Point] = []
        for entry in entries {
            guard case .object(let o) = entry,
                  case .number(let x)? = o["x"],
                  case .number(let y)? = o["y"] else { return nil }
            parsed.append(Point(x: x, y: y))
        }
        self.init(points: parsed)
    }
}
