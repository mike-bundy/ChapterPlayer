//
//  Entity+Opacity.swift
//  SharedVisions
//
//  OpacityComponent wrapper with a `fadeOpacity(to:duration:timing:)` helper.
//  Mirrors Apple's CreatingASpaceshipGame/Entity+Spaceship.swift pattern.
//

import Foundation
import RealityKit

extension Entity {
    /// The opacity value applied to the entity and its descendants.
    ///
    /// `OpacityComponent` is assigned to the entity if it doesn't already exist.
    public var opacity: Float {
        get {
            return components[OpacityComponent.self]?.opacity ?? 1
        }
        set {
            if !components.has(OpacityComponent.self) {
                components[OpacityComponent.self] = OpacityComponent(opacity: newValue)
            } else {
                components[OpacityComponent.self]?.opacity = newValue
            }
        }
    }

    /// Fades the entity's opacity to a target value with animation.
    ///
    /// For `duration == 0`, sets opacity immediately (synchronous snap — load-bearing
    /// for same-loop ordering where snap must complete before `showEntity` in the
    /// same step action array).
    ///
    /// - Parameters:
    ///   - targetOpacity: Target opacity value (0.0 to 1.0)
    ///   - duration: Animation duration in seconds (default: 1.0). Duration of 0 snaps immediately.
    ///   - timing: Animation timing curve (default: .easeInOut)
    @MainActor
    public func fadeOpacity(to targetOpacity: Float,
                    duration: TimeInterval = 1.0,
                    timing: RealityKit.AnimationTimingFunction = .easeInOut) {
        guard duration > 0 else {
            self.opacity = targetOpacity
            return
        }

        let startOpacity = self.opacity
        let animation = FromToByAnimation(
            from: startOpacity,
            to: targetOpacity,
            duration: duration,
            timing: timing,
            bindTarget: .opacity
        )

        components.set(OpacityComponent(opacity: startOpacity))
        guard let resource = try? AnimationResource.generate(with: animation) else {
            assertionFailure("Failed to generate opacity animation for \(self.name)")
            self.opacity = targetOpacity
            return
        }
        playAnimation(resource)
    }
}
