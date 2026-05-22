//
//  Transform+HeadSampling.swift
//  SharedVisions
//
//  One-shot head sampling via ARKit WorldTrackingProvider, plus Transform helpers
//  used by EntityActionExecutor's head-relative positioning math.
//

import ARKit
import QuartzCore
import RealityKit

extension WorldTrackingProvider {
    /// Samples the current device transform once.
    ///
    /// - Parameter leveled: If `true`, strips pitch and roll from the rotation
    ///   so "in front of the user" follows yaw only.
    /// - Returns: The sampled transform, or `nil` when world tracking is not ready.
    public func sampleDeviceTransform(leveled: Bool = true) -> Transform? {
        guard case .running = self.state,
              let anchor = self.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }

        let fullTransform = Transform(matrix: anchor.originFromAnchorTransform)
        return leveled ? fullTransform.withLeveledOrientation() : fullTransform
    }
}

extension Transform {
    /// Returns a copy with pitch and roll stripped from the rotation.
    /// Preserves translation and yaw so placement stays level in world space.
    nonisolated func withLeveledOrientation() -> Transform {
        let matrix = simd_float4x4(self.rotation)
        let forward = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)

        var projected = SIMD3<Float>(forward.x, 0, forward.z)
        let magnitudeSquared = length_squared(projected)
        if magnitudeSquared < 1e-6 {
            projected = SIMD3<Float>(0, 0, 1)
        } else {
            projected = normalize(projected)
        }

        let yaw = atan2(projected.x, projected.z)
        let yawRotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

        return Transform(scale: self.scale, rotation: yawRotation, translation: self.translation)
    }

    /// Converts a local-space offset into a world-space position using this transform.
    nonisolated func worldPosition(forLocalOffset localOffset: SIMD3<Float>) -> SIMD3<Float> {
        translation + rotation.act(localOffset)
    }
}
