//
//  PulseRingEntity.swift
//  SharedVisions
//
//  Example VFX #1 — a ring of emissive discs surrounding the user, pulsing on a sine wave.
//
//  Archetype: persistent ambient spatial VFX.
//  Re-skinned from the HSBC ParticleFieldEntity pattern (which was an 18×28 wall of
//  tiny sprites). This is a ring of solid meshes, larger per-element, fewer total,
//  different shape and layout — showcases how the effect system scales to different
//  aesthetics.
//

import RealityKit
import Foundation
import simd
import UIKit

@MainActor
public final class PulseRingEntity: Entity {

    private var discs: [ModelEntity] = []
    private var config: PulseRingConfig = PulseRingConfig()
    private var isPausedFlag = false
    private var animationTask: Task<Void, Never>?

    // MARK: - Configuration

    public func configure(_ config: PulseRingConfig) {
        self.config = config
        rebuildDiscs()
        startAnimation()
    }

    public func setPaused(_ paused: Bool) {
        self.isPausedFlag = paused
    }

    private func rebuildDiscs() {
        // Remove existing discs before rebuilding
        for disc in discs {
            disc.removeFromParent()
        }
        discs.removeAll()

        let discMesh = MeshResource.generateSphere(radius: config.discRadius)
        let tint = UIColor(
            red: CGFloat(config.colorRed),
            green: CGFloat(config.colorGreen),
            blue: CGFloat(config.colorBlue),
            alpha: 1.0
        )

        for i in 0..<config.ringCount {
            let angle = (Float(i) / Float(config.ringCount)) * 2 * .pi
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: tint.withAlphaComponent(0.9))
            material.metallic = .init(floatLiteral: 0.2)
            material.roughness = .init(floatLiteral: 0.5)
            material.emissiveColor = .init(color: tint)
            material.emissiveIntensity = config.baseIntensity
            // Keep blending on so we can fade via OpacityComponent if needed.
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))

            let disc = ModelEntity(mesh: discMesh, materials: [material])
            disc.name = "pulseRingDisc_\(i)"
            disc.position = SIMD3<Float>(
                cos(angle) * config.radius,
                config.height,
                sin(angle) * config.radius
            )
            // Orient disc toward ring center for a subtle directional look.
            disc.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

            addChild(disc)
            discs.append(disc)
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        animationTask?.cancel()
        animationTask = Task { @MainActor [weak self] in
            let start = Date.now
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPausedFlag {
                    let t = Float(Date.now.timeIntervalSince(start))
                    self.updatePulse(time: t)
                }
                try? await Task.sleep(for: .milliseconds(33))  // ~30Hz — plenty for ambient pulse
            }
        }
    }

    private func updatePulse(time: Float) {
        let cfg = config
        let amp = cfg.peakIntensity - cfg.baseIntensity
        for (i, disc) in discs.enumerated() {
            let phase = Float(i) / Float(max(cfg.ringCount, 1)) * 2 * .pi
            let pulse = 0.5 + 0.5 * sin(time * cfg.pulseSpeed * 2 * .pi + phase)
            let intensity = cfg.baseIntensity + amp * pulse
            if var material = disc.model?.materials.first as? PhysicallyBasedMaterial {
                material.emissiveIntensity = intensity
                disc.model?.materials = [material]
            }
        }
    }

    // MARK: - Lifecycle

    required init() {
        super.init()
        self.name = "PulseRing"
    }
}
