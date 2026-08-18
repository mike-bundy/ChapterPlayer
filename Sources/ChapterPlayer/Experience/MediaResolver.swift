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
    /// Implementations should be cheap: callers may invoke many times per sequence.
    func url(for assetId: String, kind: MediaKind) -> URL?
}

/// Default resolver — preserves the legacy behavior of `SpatialAudioManager` /
/// `VideoPlaybackManager` so existing sequences keep working unchanged.
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
        // MANIFEST FIRST — it is authoritative, and it is the only thing that
        // can express an asset stored under a different name or in a subfolder.
        if let rel = pathById[assetId], let url = existing(assetsRoot.appending(path: rel)) {
            return url
        }

        // THEN THE OBVIOUS PLACE: `assets/<assetId>`.
        //
        // An asset id in this format IS a filename — `AudioActionDTO.file`,
        // `VideoActionDTO.file` and the entity ids all carry one — so a file
        // sitting in `assets/` under exactly the requested name is the asset,
        // manifest entry or no manifest entry.
        //
        // Refusing it was a real failure, found on device: a bundle whose
        // manifest was empty resolved NOTHING. Every cue fell through to the
        // app's shipped Media.bundle, found nothing there either, and playback
        // was silent — "Ambient audio DROPPED" for every file, with the files
        // plainly present in `assets/`. The manifest carries integrity data
        // (hashes, renames); it was never meant to be the addressing scheme,
        // and treating it as one makes any hand-authored or hand-edited bundle
        // unplayable.
        return existing(assetsRoot.appending(path: assetId))
    }

    /// `path(percentEncoded: false)` — NOT `path()`.
    ///
    /// `URL.path()` percent-encodes by default, so an iCloud Drive path arrives
    /// as ".../Mobile%20Documents/..." and `FileManager`, which speaks raw
    /// filesystem paths, reports the file missing. Any path containing a space
    /// fails — and iCloud Drive's real directory is literally "Mobile
    /// Documents".
    private func existing(_ candidate: URL) -> URL? {
        FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
            ? candidate : nil
    }
}
