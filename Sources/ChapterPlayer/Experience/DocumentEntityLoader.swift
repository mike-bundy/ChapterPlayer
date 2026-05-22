//
//  DocumentEntityLoader.swift
//  ChapterPlayer
//
//  Walks a `ChapterScript.ExperienceDocument`'s entities, builds them via
//  `EntityFactory`, and registers each one with the chapter engine's
//  entity executor + the video manager's video-entity registry so chapter
//  actions can resolve them by id.
//
//  Decoupled from any consumer-side AppModel: the consumer supplies the
//  two executors directly. The optional `ambientBackdropName` lets a
//  consuming app hide a static Reality Composer Pro scene while a live
//  experience is loaded — that's a product convention, not part of the
//  engine.
//

import Foundation
import RealityKit
import OSLog
import ChapterScript

private let docEntityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.chapterplayer",
    category: "DocumentEntities"
)

@MainActor
public final class DocumentEntityLoader {

    private let factory: EntityFactory
    private weak var entityExecutor: EntityActionExecutor?
    private weak var videoManager: VideoPlaybackManager?
    /// Optional name of an ambient scene child (e.g. a Reality Composer Pro
    /// "RealityComposerBackdrop" anchor) that the consumer wants disabled
    /// while a document is materialized and re-enabled on unload. Pass
    /// `nil` to skip this behavior entirely.
    private let ambientBackdropName: String?

    /// Names registered with `entityExecutor` and `videoEntityRegistry`
    /// during the last `materialize` pass, so the next call can clear
    /// them before installing a fresh document's entities.
    private var registeredNames: Set<String> = []

    /// Anchor under the immersive root that owns every document-spawned
    /// entity. Replaced wholesale on each `materialize` so old docs don't
    /// leak children into the scene.
    private var anchor: Entity?

    public init(
        entityExecutor: EntityActionExecutor,
        videoManager: VideoPlaybackManager,
        factory: EntityFactory = EntityFactory(),
        ambientBackdropName: String? = nil
    ) {
        self.entityExecutor = entityExecutor
        self.videoManager = videoManager
        self.factory = factory
        self.ambientBackdropName = ambientBackdropName
    }

    /// Build every entity in `document.entities` and wire it into the
    /// scene + executors. Idempotent: a second call with a new document
    /// removes the prior batch first.
    public func materialize(document: ExperienceDocument, sceneRoot: Entity?) {
        unload()

        guard let entityExecutor, let videoManager else { return }
        guard let root = sceneRoot else {
            docEntityLogger.warning("materialize called before sceneRoot was wired; skipping")
            return
        }

        // Optionally hide a consumer-provided ambient backdrop while a
        // live document is loaded so static scenery doesn't blend into
        // the author's scene.
        if let name = ambientBackdropName,
           let backdrop = root.children.first(where: { $0.name == name }) {
            backdrop.isEnabled = false
        }

        let anchor = Entity()
        anchor.name = "DocumentEntities"
        root.addChild(anchor)
        self.anchor = anchor

        var built = 0
        for definition in document.entities {
            guard let entity = factory.build(definition) else {
                docEntityLogger.warning("EntityFactory could not build '\(definition.id)' (kind=\(String(describing: definition.kind)))")
                continue
            }

            // Disable by default — chapter actions reveal what they want
            // visible. Matches the engine's `stop(resetEntities: true)`
            // semantics so the doc's entities behave like pre-registered
            // ones.
            entity.isEnabled = false
            anchor.addChild(entity)

            entityExecutor.register(entity, name: definition.id)
            registeredNames.insert(definition.id)

            // VideoPanel entities are *also* discoverable by the
            // VideoPlaybackManager so `.entity(name:)` presentation can
            // bind a `VideoMaterial` on the right plane.
            if definition.kind == .videoPanel {
                videoManager.videoEntityRegistry[definition.id] = entity
            }

            built += 1
        }

        docEntityLogger.info("Materialized \(built) document entit\(built == 1 ? "y" : "ies") into the scene")
    }

    /// Tear down the previous batch of document-spawned entities. Called
    /// before re-materializing on a new document, and on phase transition
    /// out of the immersive space. Re-enables the optional ambient
    /// backdrop so a subsequent bundled-content play still gets its
    /// authored scenery.
    public func unload() {
        guard let entityExecutor, let videoManager else { return }
        for name in registeredNames {
            entityExecutor.unregister(name: name)
            videoManager.videoEntityRegistry.removeValue(forKey: name)
        }
        registeredNames.removeAll()
        if let name = ambientBackdropName,
           let parent = anchor?.parent,
           let backdrop = parent.children.first(where: { $0.name == name }) {
            backdrop.isEnabled = true
        }
        anchor?.removeFromParent()
        anchor = nil
    }
}
