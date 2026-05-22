//
//  AttachmentActionExecutor.swift
//  SharedVisions
//
//  Handles SwiftUI attachment visibility and view switching in 3D space.
//

import RealityKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "AttachmentActionExecutor"
)

// MARK: - Protocol

@MainActor
public protocol AttachmentActionExecutorProtocol {
    func show(attachmentId: String)
    func hide(attachmentId: String)
    func hideAll()
    func fade(attachmentId: String, opacity: Float, duration: TimeInterval)
    func setView(attachmentId: String, viewId: String)
}

// MARK: - Implementation

@MainActor
public final class AttachmentActionExecutor: AttachmentActionExecutorProtocol {


    public init() {}
    /// Attachment entity references (set by ImmersiveView)
    public var attachmentEntities: [String: Entity] = [:]

    /// Callback for view switching — the overlay views observe this
    public var onViewChange: ((String, String) -> Void)?

    public func show(attachmentId: String) {
        if let entity = attachmentEntities[attachmentId] {
            entity.opacity = 1.0
            entity.isEnabled = true
            logger.debug("Show attachment: \(attachmentId)")
        } else {
            logger.warning("show: attachment '\(attachmentId)' not found")
        }
    }

    public func hide(attachmentId: String) {
        if let entity = attachmentEntities[attachmentId] {
            entity.isEnabled = false
            logger.debug("Hide attachment: \(attachmentId)")
        } else {
            logger.warning("hide: attachment '\(attachmentId)' not found")
        }
    }

    public func fade(attachmentId: String, opacity: Float, duration: TimeInterval) {
        if let entity = attachmentEntities[attachmentId] {
            entity.fadeOpacity(to: opacity, duration: duration)
            logger.debug("Fade attachment: \(attachmentId) to \(opacity) over \(String(format: "%.1f", duration))s")
        } else {
            logger.warning("fade: attachment '\(attachmentId)' not found")
        }
    }

    public func hideAll() {
        for (id, entity) in attachmentEntities {
            entity.isEnabled = false
            logger.debug("Hide attachment (hideAll): \(id)")
        }
    }

    public func setView(attachmentId: String, viewId: String) {
        onViewChange?(attachmentId, viewId)
        logger.debug("Set view: \(attachmentId) → \(viewId)")
    }
}
