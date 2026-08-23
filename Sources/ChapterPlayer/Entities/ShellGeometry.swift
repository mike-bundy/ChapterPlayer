//
//  ShellGeometry.swift
//  ChapterPlayer
//
//  FIELD-AWARE ENVIRONMENT SHELL for immersive image backdrops — the
//  runtime twin of `MaestroKit.BackdropGeometry`, vendored because this
//  package cannot depend on MaestroKit (it lives inside the chapterengine
//  repo and is consumed by path). THE CONVENTIONS ARE A CONTRACT and the
//  two files must stay in lock-step: a shell the editor previews and the
//  shell the player renders must be the same shell.
//
//  COORDINATE CONVENTION — matches the rest of the engine:
//    • Canonical forward is -Z; +Y is up.
//    • Azimuth θ measured from +Z increasing toward +X
//          x = r · sinφ · sinθ      z = r · sinφ · cosθ
//      so θ = 0 is BEHIND the viewer and θ = π is forward (-Z).
//    • A 180° field spans θ ∈ [π/2, 3π/2]: the front hemisphere only.
//    • Polar angle φ runs 0 (up) to π (down): y = r · cosφ.
//
//  WINDING: triangles wind for OUTWARD faces, same as
//  `MeshResource.generateSphere` — the host applies the established
//  `scale = (-1, 1, 1)` interior inversion, keeping texture handedness
//  identical between the full-sphere and partial-shell paths.
//
//  UV: v is FLIPPED (v = 1 at the top) to match RealityKit's own
//  sphere convention — the same named flip `BackdropGeometry` carries,
//  for the same reason: the 360° path renders right way up through
//  `generateSphere`, and the partial shell must agree with it.
//
//  What the Simulator can prove about this file: span, bounds, forward
//  centring, UV corners (`MaestroVisionTests/ShellGeometryTests`).
//  UV mirroring as PERCEIVED, stereo eye orientation and real
//  perceptual correctness remain DEFERRED-HARDWARE-QA.
//

import Foundation
import simd

enum ShellGeometry {

    struct Shell {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var uvs: [SIMD2<Float>]
        var indices: [UInt32]

        var vertexCount: Int { positions.count }
        var triangleCount: Int { indices.count / 3 }
    }

    /// Horizontal sweep in radians, from the field's authored coverage —
    /// `horizontalDegrees` is the ONE place a field becomes an angle.
    static func azimuthSpan(for field: ImmersiveField) -> Float {
        field.horizontalDegrees * .pi / 180
    }

    /// Middle of the sweep: always forward (-Z, θ = π).
    static let forwardAzimuth: Float = .pi

    /// Convention match to `generateSphere`'s UV mapping (see header).
    static let flipVerticalUV = true

    /// Build the shell. Columns default to equal ANGULAR resolution
    /// (a 190° shell gets 190°'s worth of columns, not a fixed count).
    static func shell(
        field: ImmersiveField,
        radius: Float,
        columns: Int? = nil,
        rows: Int = 32
    ) -> Shell {
        let span = azimuthSpan(for: field)
        let safeRadius = max(radius, 0.01)
        let cols = max(columns ?? Int((span / (2 * .pi)) * 64), 3)
        let rowCount = max(rows, 2)

        let start = forwardAzimuth - span / 2

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity((cols + 1) * (rowCount + 1))

        for row in 0...rowCount {
            let v = Float(row) / Float(rowCount)
            let phi = v * .pi
            let sinPhi = sin(phi)
            let cosPhi = cos(phi)

            for col in 0...cols {
                let u = Float(col) / Float(cols)
                let theta = start + u * span
                let direction = SIMD3<Float>(
                    sinPhi * sin(theta),
                    cosPhi,
                    sinPhi * cos(theta)
                )
                positions.append(direction * safeRadius)
                normals.append(direction)
                uvs.append(SIMD2<Float>(u, flipVerticalUV ? 1 - v : v))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(cols * rowCount * 6)
        let stride = cols + 1
        for row in 0..<rowCount {
            for col in 0..<cols {
                let topLeft = UInt32(row * stride + col)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * stride + col)
                let bottomRight = bottomLeft + 1
                // Pole-degenerate triangles are skipped, not emitted.
                if row != 0 {
                    indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                }
                if row != rowCount - 1 {
                    indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
                }
            }
        }

        return Shell(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }

    // MARK: - Measurement (for tests)

    /// Angular extent covered by the shell's vertices, measured RELATIVE
    /// TO FORWARD (`atan2(x, -z)`) to avoid the branch cut at ±π.
    static func measuredAzimuthSpan(of shell: Shell) -> Float {
        var minTheta = Float.greatestFiniteMagnitude
        var maxTheta = -Float.greatestFiniteMagnitude
        for position in shell.positions {
            let horizontal = simd_length(SIMD2<Float>(position.x, position.z))
            guard horizontal > 1e-4 else { continue }
            let theta = atan2(position.x, -position.z)
            minTheta = min(minTheta, theta)
            maxTheta = max(maxTheta, theta)
        }
        guard minTheta <= maxTheta else { return 0 }
        return maxTheta - minTheta
    }

    /// Largest angle any vertex sits from forward. A 180° shell never
    /// exceeds π/2 — that is precisely "no rear hemisphere".
    static func maxAngleFromForward(of shell: Shell) -> Float {
        var maxAngle: Float = 0
        for position in shell.positions {
            let horizontal = simd_length(SIMD2<Float>(position.x, position.z))
            guard horizontal > 1e-4 else { continue }
            maxAngle = max(maxAngle, abs(atan2(position.x, -position.z)))
        }
        return maxAngle
    }
}
