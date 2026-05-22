//
//  VideoScreenEntity.swift
//  SharedVisions
//
//  Reusable floating screen entity for in-scene video playback.
//  Uses a plane mesh with VideoPlayerComponent.
//

import RealityKit
import AVFoundation
import UIKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "VideoScreenEntity"
)

public class VideoScreenEntity: Entity {

    private var screenModel: ModelEntity?

    /// Create a video screen with the given dimensions.
    @MainActor
    public func setup(width: Float = 2.0, height: Float = 1.125) {
        // Create a plane for the video
        let mesh = MeshResource.generatePlane(width: width, height: height)

        // Clear backing — video content fills the plane, no visible edge
        var material = UnlitMaterial(color: .clear)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.0))
        material.writesDepth = false

        let model = ModelEntity(mesh: mesh, materials: [material])
        model.name = "VideoScreen"

        addChild(model)
        screenModel = model

        // Start hidden
        isEnabled = false
        
        logger.info("VideoScreenEntity setup: \(width)×\(height)m")
    }
}
