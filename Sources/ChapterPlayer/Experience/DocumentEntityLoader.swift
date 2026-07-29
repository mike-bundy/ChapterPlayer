//
//  DocumentEntityLoader.swift
//  ChapterPlayer
//
//  Walks a `ChapterScript.ChapterDocument`'s entities, builds them via
//  `EntityFactory`, and registers each one with the segment engine's
//  entity executor + the video manager's video-entity registry so segment
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
    public func materialize(document: ChapterDocument, sceneRoot: Entity?, mediaResolver: MediaResolver? = nil) {
        unload()

        // Give the factory the resolver so image entities ("Add Image"
        // reveals) can locate their files and render as textured planes.
        factory.mediaResolver = mediaResolver

        // Preset lookup for `.particles` entities. Rebuilt on every
        // materialize so a live-sync preset upsert (or a changed entity
        // binding) re-renders with the fresh values — materialize rebuilds
        // all document entities from scratch, nothing here is cached.
        factory.particlePresets = Dictionary(
            document.particlePresets.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

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

            // Disable by default — segment actions reveal what they want
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

    /// Incrementally build (or rebuild) ONE entity from a live-edit
    /// upsert without tearing down the whole document scene. A full
    /// `materialize` re-loads every USDZ (`Entity(contentsOf:)` per
    /// asset) and re-binds every video panel — far too heavy, and far
    /// too memory-spiky, to run once per imported media file: the old
    /// and new copies of every loaded model are resident simultaneously
    /// during the rebuild.
    ///
    /// Returns `false` when no prior `materialize` pass has run (no
    /// anchor to parent under) or the factory can't build the
    /// definition — callers fall back to the full pass.
    @discardableResult
    public func materializeOne(
        _ definition: EntityDefinition,
        document: ChapterDocument,
        mediaResolver: MediaResolver? = nil
    ) -> Bool {
        guard let entityExecutor, let videoManager, let anchor else { return false }

        if let mediaResolver { factory.mediaResolver = mediaResolver }

        // Presets may have changed since the last full pass; `.particles`
        // entities resolve against this map at build time.
        factory.particlePresets = Dictionary(
            document.particlePresets.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        guard let entity = factory.build(definition) else {
            docEntityLogger.warning("materializeOne could not build '\(definition.id)' (kind=\(String(describing: definition.kind)))")
            return false
        }

        // Replace any previous incarnation of this entity.
        if registeredNames.contains(definition.id) {
            anchor.children.first(where: { $0.name == definition.id })?.removeFromParent()
            entityExecutor.unregister(name: definition.id)
            videoManager.videoEntityRegistry.removeValue(forKey: definition.id)
            registeredNames.remove(definition.id)
        }

        // Same contract as the full pass: disabled by default, segment
        // actions reveal what they want visible.
        entity.isEnabled = false
        anchor.addChild(entity)
        entityExecutor.register(entity, name: definition.id)
        registeredNames.insert(definition.id)
        if definition.kind == .videoPanel {
            videoManager.videoEntityRegistry[definition.id] = entity
        }
        docEntityLogger.info("Incrementally materialized '\(definition.id)'")
        return true
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
