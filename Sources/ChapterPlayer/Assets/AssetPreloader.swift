//
//  AssetPreloader.swift
//  SharedVisions
//
//  Stub preloader matching the HSBC AssetPreloader shape.
//  SharedVisions has no Models3D.bundle yet; this exists so future USDZ assets
//  follow the same pattern (preloadAll() async; cloneX() returning independent copies).
//

import RealityKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "AssetPreloader"
)

@MainActor
@Observable
public final class AssetPreloader {


    public init() {}
    /// True once `preloadAll()` has finished (success or failure).
    public private(set) var isLoaded: Bool = false

    /// Last error encountered during preload, if any.
    public private(set) var loadError: Error?

    /// Singleton task guard — reentrant calls return the same in-flight task.
    private var preloadTask: Task<Void, Never>?

    // MARK: - Preloaded masters (populate as assets are added)
    //
    // Example shape for future USDZ assets:
    //
    //   private(set) var hsbcLogoEntity: Entity?
    //   func cloneHsbcLogo() -> Entity? { hsbcLogoEntity?.clone(recursive: true) }
    //
    // Preload inside `preloadAll()`:
    //
    //   async let logo = loadAsset(named: "hsbc-scene", ext: "usda", subdirectory: "hsbc_logo")
    //   self.hsbcLogoEntity = await logo

    // MARK: - Public API

    public func preloadAll() async {
        if isLoaded { return }
        if let existing = preloadTask {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            let start = Date()
            defer { logger.info("AssetPreloader: preloadAll finished in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s") }

            // Intentionally empty: SharedVisions ships with no USDZ assets yet.
            // When assets are added, load them here in parallel via `async let`.
            self.isLoaded = true
        }
        preloadTask = task
        await task.value
    }

    // MARK: - Generic loader (available for future use)

    /// Loads an entity from the app bundle. Searches the main bundle and optional subdirectory.
    /// Returns nil if the asset is missing; logs an error but does not throw so callers can degrade gracefully.
    public func loadAsset(named name: String, ext: String, subdirectory: String? = nil) async -> Entity? {
        let url: URL?
        if let subdir = subdirectory {
            url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir)
                ?? Bundle.main.url(forResource: name, withExtension: ext)
        } else {
            url = Bundle.main.url(forResource: name, withExtension: ext)
        }
        guard let assetURL = url else {
            logger.error("AssetPreloader: asset not found — \(name).\(ext) (subdir=\(subdirectory ?? "nil"))")
            return nil
        }
        do {
            return try await Entity(contentsOf: assetURL)
        } catch {
            logger.error("AssetPreloader: failed to load \(assetURL.lastPathComponent) — \(error.localizedDescription)")
            self.loadError = error
            return nil
        }
    }
}
