//
//  ImmersiveGrading.swift
//  ChapterPlayer
//
//  FL-09: CAN THIS IMMERSIVE SOURCE BE GRADED, AND IF NOT, WHY.
//
//  A flat panel is drawn with a material, so the Effect surface has a slot
//  to write into. An immersive source is normally drawn by
//  `VideoPlayerComponent`, which owns its pixels end to end and has no
//  per-frame hook — that is the real reason an authored backdrop stack
//  reached the runtime and stopped there, and it is not something a
//  different call order fixes.
//
//  A MESH does have a slot, and `ShellGeometry` already builds the shell the
//  image-backdrop path mounts. So a mono immersive source with an enabled
//  stack is mounted as a mesh and graded like any panel.
//
//  STEREO IS NOT. One texture holds one eye. Flattening a stereo plate to
//  apply a grade would trade the viewer's depth for a color decision, on
//  their behalf, silently — so the component stays, both eyes stay correct,
//  and the stack is reported unrendered by name. That is a limit with a
//  stated unblock (a two-texture surface, one per eye), not a bug.
//
//  Pure so the rule can be tested without a scene: a layout and a stack in,
//  a decision out.
//

import Foundation
import ChapterScript

public enum ImmersiveGrading {

    public enum Decision: Equatable, Sendable {
        /// No enabled Effects — mount exactly as before.
        case noStack
        /// Mount as a mesh and let the Effect surface write into it.
        case graded
        /// Keep `VideoPlayerComponent`; the stack does not render. The
        /// reason names the layout, because "it didn't work" is not a
        /// thing an author can act on.
        case unrendered(reason: String)
    }

    public static func decision(layout: VideoLayout,
                                effects: [EffectInstance]?) -> Decision {
        guard let effects, effects.contains(where: \.enabled) else { return .noStack }
        switch layout {
        case .mono:
            return .graded
        case .sideBySide, .overUnder, .multiviewHEVC:
            return .unrendered(reason: sentence(for: layout))
        }
    }

    /// ONE sentence per layout, in the player's own voice — the host logs it
    /// and a future author-facing surface can show the same words.
    public static func sentence(for layout: VideoLayout) -> String {
        let name: String
        switch layout {
        case .mono:           name = "mono"
        case .sideBySide:     name = "side-by-side stereo"
        case .overUnder:      name = "over-under stereo"
        case .multiviewHEVC:  name = "MV-HEVC stereo"
        }
        return "Effects don't render on a \(name) immersive source: it plays "
            + "through the system's own stereo path, which has no per-frame "
            + "surface. Grading it would mean flattening it to one eye."
    }
}
