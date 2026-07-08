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
    ///
    /// Thin wrapper over `ChapterScript.MotionCurveSampling` — the ONE
    /// motion-sampling truth shared with the editors (scrub previews,
    /// motion trails, graph rendering all sample the same math).
    static public func evaluate(_ curve: MotionCurve, t: Float, absoluteTime: Float) -> SIMD3<Float> {
        MotionCurveSampling.sample(curve, t: t, absoluteTime: absoluteTime)
    }
}
