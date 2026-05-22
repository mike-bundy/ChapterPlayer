//
//  MotionCurveEvaluator.swift
//  SharedVisions
//
//  Pure evaluator for ChapterScript.MotionCurve. Same evaluator drives all
//  three channels (position / scale / rotation-as-axis-angle); the channel
//  applier interprets the resulting Vec3 accordingly.
//
//  Conventions
//  -----------
//  - `t` is normalized step progress, clamped to [0, 1].
//  - `absoluteTime` is seconds since chapter start; `oscillate` and `rotate`
//    use it where they need real-time-locked behavior.
//  - `oscillate.frequency` is in Hz (cycles per second of absoluteTime).
//  - `rotate(axis, revolutions)` returns axis * angleInRadians where
//    angle = revolutions * 2π * t — i.e. the rotation completes `revolutions`
//    full turns over the step. Position-channel applies treat the result as
//    a position offset (rarely useful); rotation-channel applies treat the
//    Vec3 as an axis-angle vector.
//

import Foundation
import simd
import ChapterScript

public enum MotionCurveEvaluator {

    /// Evaluate `curve` at normalized step progress `t` and seconds-since-start `absoluteTime`.
    /// Returns a `SIMD3<Float>` ready for direct assignment to entity transforms.
    static public func evaluate(_ curve: MotionCurve, t: Float, absoluteTime: Float) -> SIMD3<Float> {
        let clamped = max(0, min(1, t))
        switch curve {
        case .constant(let v):
            return SIMD3(v)

        case .linear(let from, let to):
            let f = SIMD3(from)
            let to = SIMD3(to)
            return mix(f, to, t: clamped)

        case .orbit(let center, let radius, let axis, let revolutions, let phase):
            let angle = (clamped * revolutions + phase) * 2 * .pi
            return orbitPoint(center: SIMD3(center), radius: radius, axis: SIMD3(axis), angle: angle)

        case .spiral(let center, let startRadius, let endRadius, let axis, let revolutions, let yRise):
            let angle = clamped * revolutions * 2 * .pi
            let r = lerp(startRadius, endRadius, t: clamped)
            var p = orbitPoint(center: SIMD3(center), radius: r, axis: SIMD3(axis), angle: angle)
            p.y += yRise * clamped
            return p

        case .oscillate(let axis, let amplitude, let frequency, let waveform):
            let phase = absoluteTime * frequency * 2 * .pi
            let scalar = amplitude * waveform.sample(phase: phase)
            return SIMD3(axis) * scalar

        case .rotate(let axis, let revolutions):
            let angle = clamped * revolutions * 2 * .pi
            return normalizeOrZero(SIMD3(axis)) * angle

        case .keyframes(let pts):
            return sampleKeyframes(pts, t: clamped)

        case .sum(let curves):
            return curves.reduce(SIMD3<Float>.zero) {
                $0 + evaluate($1, t: clamped, absoluteTime: absoluteTime)
            }

        case .scaled(let inner, let factor):
            return evaluate(inner, t: clamped, absoluteTime: absoluteTime) * factor
        }
    }

    // MARK: - Helpers

    /// Linear interpolation. `t` is unclamped — callers should clamp first.
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private static func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }

    private static func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = simd_length(v)
        return len > 0 ? v / len : .zero
    }

    /// Returns a point on the circle of given `radius` around `center`, normal to `axis`,
    /// rotated to `angle`. Builds an orthonormal basis from `axis`.
    private static func orbitPoint(
        center: SIMD3<Float>,
        radius: Float,
        axis: SIMD3<Float>,
        angle: Float
    ) -> SIMD3<Float> {
        let n = normalizeOrZero(axis)
        if n == .zero { return center }
        // Pick a vector not parallel to `n` to seed the basis.
        let helper: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = normalizeOrZero(simd_cross(n, helper))
        let v = simd_cross(n, u)
        let offset = u * (cos(angle) * radius) + v * (sin(angle) * radius)
        return center + offset
    }

    /// Linear interpolate between adjacent keyframes by time. For Phase 2 this
    /// honors `linear`, `easeIn/Out/InOut`, and `step`; bezier/spring fall back
    /// to ease-in-out until tangent-aware sampling lands.
    private static func sampleKeyframes(_ pts: [KeyframePoint], t: Float) -> SIMD3<Float> {
        guard !pts.isEmpty else { return .zero }
        if pts.count == 1 || t <= pts.first!.time { return SIMD3(pts.first!.value) }
        if t >= pts.last!.time { return SIMD3(pts.last!.value) }

        // Find the surrounding pair.
        var lower = pts.first!
        var upper = pts.last!
        for i in 0..<(pts.count - 1) {
            if pts[i].time <= t && pts[i + 1].time >= t {
                lower = pts[i]
                upper = pts[i + 1]
                break
            }
        }
        let span = upper.time - lower.time
        let local = span > 0 ? (t - lower.time) / span : 0
        let eased = applyEasing(local, mode: lower.interpolation)
        return mix(SIMD3(lower.value), SIMD3(upper.value), t: eased)
    }

    private static func applyEasing(_ t: Float, mode: InterpolationMode) -> Float {
        switch mode {
        case .step:       return t < 1 ? 0 : 1
        case .linear:     return t
        case .easeIn:     return t * t
        case .easeOut:    return 1 - (1 - t) * (1 - t)
        case .easeInOut:
            return t < 0.5
                ? 2 * t * t
                : 1 - pow(-2 * t + 2, 2) / 2
        case .bezier, .spring:
            // Phase-2 fallback. Tangent/spring sampling can be added when an
            // experience actually authors them.
            return t < 0.5
                ? 2 * t * t
                : 1 - pow(-2 * t + 2, 2) / 2
        }
    }
}

private extension Waveform {
    /// `phase` is in radians.
    public func sample(phase: Float) -> Float {
        switch self {
        case .sine:
            return sin(phase)
        case .absSine:
            return abs(sin(phase))
        case .triangle:
            // Period is 2π; output in [-1, 1].
            let twoPi = 2 * Float.pi
            let p = phase.truncatingRemainder(dividingBy: twoPi)
            let normalized = p < 0 ? p + twoPi : p
            let unit = normalized / twoPi // 0..<1
            return unit < 0.5
                ? -1 + 4 * unit
                : 3 - 4 * unit
        case .square:
            return sin(phase) >= 0 ? 1 : -1
        }
    }
}
