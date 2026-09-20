//
//  ImmersiveMount.swift
//  ChapterPlayer
//
//  HOW AN IMMERSIVE VIDEO IS MOUNTED: the system player, or our own shell.
//
//  `VideoPlayerComponent` decides projection from the FILE, and only from the
//  file: a `ProjectionKind` in the video track's format description, and the
//  coded-view count for MV-HEVC. It is the only path that renders two eyes,
//  and the only one that knows Apple Immersive's parametric lens. But handed a
//  plain equirect master with NO projection tag, which is what most 180 and
//  360 footage is, it has nothing to go on and presents a FLAT RECTANGLE. The
//  authored field (`ImmersiveField`) reached the runtime and was bound to `_`:
//  the Mac Viewer showed the author a 190° shell and the headset showed a
//  screen.
//
//  The precedence is the editor's own (`EXPORT_RENDERING` §0.5): DECLARED
//  metadata, then the AUTHORED decision, and nothing guessed.
//
//  Pure, so the table is tested without a scene.
//

import Foundation
import ChapterScript

public enum ImmersiveMount {

    /// What the container itself says about projection.
    public enum DeclaredProjection: Equatable, Sendable {
        /// No `ProjectionKind` at all, or one that says rectilinear: the
        /// system player would draw a flat screen.
        case none
        /// Equirectangular, half-equirectangular, Apple Immersive, or any
        /// tag the system player understands.
        case immersive
    }

    public enum Decision: Equatable, Sendable {
        /// `VideoPlayerComponent` on the empty shell entity.
        case systemPlayer
        /// A mesh of the authored field with a `VideoMaterial`.
        case shell
    }

    public static func decision(layout: VideoLayout,
                                declared: DeclaredProjection) -> Decision {
        // A file that says what it is goes to the player that reads it.
        guard declared == .none else { return .systemPlayer }
        switch layout {
        case .mono:
            // Untagged and one eye: the authored field is the only fact
            // there is, and a shell honors it exactly as the Mac Viewer does.
            return .shell
        case .sideBySide, .overUnder, .multiviewHEVC:
            // ONE TEXTURE HOLDS ONE EYE. A shell would flatten a stereo
            // master; the component keeps both eyes for MV-HEVC, and a
            // frame-packed master has no per-eye surface here yet. Losing a
            // viewer's depth is not a trade made on their behalf.
            return .systemPlayer
        }
    }

    /// Why a stereo master that carries no projection tag may not look like
    /// the authored environment, for the log and the Inspector.
    public static func advisory(layout: VideoLayout, declared: DeclaredProjection) -> String? {
        guard declared == .none, layout != .mono else { return nil }
        return "This stereo master carries no projection metadata, so the headset cannot place it on the authored shell without flattening it to one eye. Export it with projection metadata to see it as authored."
    }
}
