//
//  MediaResolver.swift
//  SharedVisions
//
//  Resolves a media reference (asset id + kind) to a concrete URL on disk.
//  Lets the engine load assets from the app bundle, a local .chapterscript
//  folder, or a downloaded Background Assets pack — without each executor
//  having to know which is in use.
//

import Foundation

public enum MediaKind: Sendable, Equatable {
    case audio
    case video
    case usdz
    case image
}

public protocol MediaResolver: Sendable {
    /// Return a file URL for the given asset id, or `nil` if not resolvable.
    /// Implementations should be cheap: callers may invoke many times per chapter.
    func url(for assetId: String, kind: MediaKind) -> URL?
}

/// Default resolver — preserves the legacy behavior of `SpatialAudioManager` /
/// `VideoPlaybackManager` so existing chapters keep working unchanged.
/// Audio/video managers may continue to fall back to their own bundle-search
/// logic if this returns nil.
public struct BundleMediaResolver: MediaResolver {
    public init() {}
    public func url(for assetId: String, kind: MediaKind) -> URL? {
        // Phase 1: defer to the existing manager-side search by returning nil.
        // The managers retain their bundle/Media.bundle lookups verbatim.
        // Future phases override this resolver with one that knows about asset packs.
        nil
    }
}

/// Reads media files relative to a `.chapterscript` directory bundle's `assets/` folder.
/// `assetId` is treated as an `AssetEntry.id`; the resolver consults the supplied
/// manifest map to translate to a relative path under `assets/`.
public struct LocalFolderMediaResolver: MediaResolver {
    /// `assets/` folder URL inside the loaded `.chapterscript` directory.
    public let assetsRoot: URL
    /// `id → relativePath` map from the loaded manifest.
    public let pathById: [String: String]

    public init(assetsRoot: URL, pathById: [String: String]) {
        self.assetsRoot = assetsRoot
        self.pathById = pathById
    }

    public func url(for assetId: String, kind: MediaKind) -> URL? {
        guard let rel = pathById[assetId] else { return nil }
        let candidate = assetsRoot.appending(path: rel)
        return FileManager.default.fileExists(atPath: candidate.path()) ? candidate : nil
    }
}
