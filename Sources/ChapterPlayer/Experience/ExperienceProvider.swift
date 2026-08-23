//
//  ExperienceProvider.swift
//  SharedVisions
//
//  Protocol-based loading for ChapterScript experience documents. Three
//  implementations are planned across phases:
//
//    LocalFolderExperienceProvider   — reads a `.chapterscript` directory bundle (this phase)
//    BundledExperienceProvider       — reads a chapter.json from the app bundle (this phase)
//    LiveDevExperienceProvider       — Bonjour + HTTP client to MaestroStudio  (Phase 5)
//
//  Background Assets-backed media resolution is folded in at the resolver level
//  (Phase 6), not here.
//

import Foundation
import ChapterScript

public struct LoadedExperience: Sendable {
    public let document: ChapterDocument
    public let mediaResolver: MediaResolver
    /// On-disk root the experience was loaded from. `nil` for synthetic / in-memory loads.
    public let rootURL: URL?

    /// Public so hosts can adopt synthetic / in-memory documents through
    /// the SAME path a provider load lands in (editor QA fixtures, tests)
    /// instead of inventing a second load path.
    public init(document: ChapterDocument, mediaResolver: MediaResolver, rootURL: URL?) {
        self.document = document
        self.mediaResolver = mediaResolver
        self.rootURL = rootURL
    }
}

public enum ExperienceLoaderError: Error, CustomStringConvertible, LocalizedError {
    case missingDocument(String)
    case malformedDocument(reason: String)
    case unreadable(URL, underlying: Error)

    public var description: String {
        switch self {
        case .missingDocument(let path):
            return "chapter.json not found at \(path)"
        case .malformedDocument(let reason):
            return "Malformed experience document: \(reason)"
        case .unreadable(let url, let err):
            return "Could not read experience at \(url.path): \(err.localizedDescription)"
        }
    }

    /// WITHOUT this, `error.localizedDescription` — which is what every caller
    /// actually shows a user — ignores `description` entirely and produces
    /// "The operation couldn't be completed. (ChapterPlayer.ExperienceLoaderError
    /// error 0.)". That is how a missing `chapter.json` reached a headset as
    /// the word "0". `CustomStringConvertible` alone is not enough; Foundation
    /// only consults `LocalizedError`.
    public var errorDescription: String? { description }
}

public protocol ExperienceProvider: Sendable {
    func load() async throws -> LoadedExperience
}

// MARK: - Local folder

/// Loads a `.chapterscript` directory bundle from any URL on disk. The directory
/// is expected to contain `chapter.json` plus an optional `assets/` subfolder.
public struct LocalFolderExperienceProvider: ExperienceProvider {
    public let folderURL: URL

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    /// Find the directory that actually holds `chapter.json`.
    ///
    /// The picked URL is usually the `.chapterscript` bundle itself, but on
    /// device it very often is not: Files hands back the ENCLOSING folder when
    /// a package is browsed into rather than selected, and AirDrop / iCloud
    /// commonly deliver the bundle nested inside a folder of the same name.
    /// Both cases produced a bare "missing document" against a path the author
    /// could see was right, which is unhelpful bordering on untrue.
    ///
    /// So: check the URL, then its immediate children, and only then give up —
    /// naming what was actually there.
    static func resolveBundleRoot(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let documentName = ChapterScriptFormat.documentFileName

        // `path(percentEncoded: false)`, NOT `path()`.
        //
        // `URL.path()` defaults to percentEncoded: true, so an iCloud Drive
        // path arrives as ".../Mobile%20Documents/..." and `FileManager`,
        // which speaks raw filesystem paths, reports the file missing. Any
        // path containing a space fails — and iCloud Drive's real directory
        // is literally "Mobile Documents". The directory LISTING still worked
        // because it goes through URLs, which is how a bundle could report
        // "no chapter.json here … Found: chapter.json".
        if fm.fileExists(atPath: url.appending(path: documentName).path(percentEncoded: false)) {
            return url
        }

        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        // Prefer a real `.chapterscript` child, then any child that holds a
        // document — a folder that merely contains one is still openable.
        let ordered = children.sorted { a, b in
            (a.pathExtension == "chapterscript" ? 0 : 1)
                < (b.pathExtension == "chapterscript" ? 0 : 1)
        }
        for child in ordered
        where fm.fileExists(atPath: child.appending(path: documentName).path(percentEncoded: false)) {
            return child
        }

        let found = children.map(\.lastPathComponent).sorted().prefix(8).joined(separator: ", ")
        throw ExperienceLoaderError.missingDocument(
            found.isEmpty
                ? "\(url.path(percentEncoded: false)) — the folder is empty or could not be read (no security-scoped access?)"
                : "\(url.path(percentEncoded: false)) — no \(documentName) here or one level down. Found: \(found)"
        )
    }

    public func load() async throws -> LoadedExperience {
        let root = try Self.resolveBundleRoot(folderURL)
        let docURL = root.appending(path: ChapterScriptFormat.documentFileName)

        let data: Data
        do {
            data = try Data(contentsOf: docURL)
        } catch {
            throw ExperienceLoaderError.unreadable(docURL, underlying: error)
        }

        let document: ChapterDocument
        do {
            // Run any pending JSON migrations forward to the current format version.
            let migrated = try Migrator.migrate(data)
            document = try ChapterScriptFormat.makeDecoder().decode(ChapterDocument.self, from: migrated)
        } catch {
            throw ExperienceLoaderError.malformedDocument(reason: String(describing: error))
        }

        let assetsRoot = root.appending(path: ChapterScriptFormat.assetsFolderName)
        let pathMap = Dictionary(
            uniqueKeysWithValues: document.manifest.entries.map { ($0.id, $0.relativePath) }
        )
        let resolver = LocalFolderMediaResolver(assetsRoot: assetsRoot, pathById: pathMap)
        return LoadedExperience(document: document, mediaResolver: resolver, rootURL: root)
    }
}

// MARK: - App bundle

/// Loads a single `chapter.json` from the app bundle. Handy for shipping a
/// canonical default experience without standing up a downloaded asset pack.
/// Media references are NOT resolved by this provider — they're expected to
/// fall back to the existing manager-side bundle search.
public struct BundledExperienceProvider: ExperienceProvider {
    /// Resource name (without extension). Defaults to "chapter" (the document
    /// file inside a `.chapterscript` bundle is `chapter.json`).
    public let resourceName: String
    /// Optional subdirectory inside the bundle, e.g. "Experiences/colorDrift.chapterscript".
    public let subdirectory: String?
    /// Bundle to search. Defaults to `Bundle.main`.
    public let bundle: Bundle

    public init(resourceName: String = "chapter", subdirectory: String? = nil, bundle: Bundle = .main) {
        self.resourceName = resourceName
        self.subdirectory = subdirectory
        self.bundle = bundle
    }

    public func load() async throws -> LoadedExperience {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json", subdirectory: subdirectory) else {
            let path = (subdirectory.map { "\($0)/" } ?? "") + "\(resourceName).json"
            throw ExperienceLoaderError.missingDocument(path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExperienceLoaderError.unreadable(url, underlying: error)
        }
        do {
            let migrated = try Migrator.migrate(data)
            let doc = try ChapterScriptFormat.makeDecoder().decode(ChapterDocument.self, from: migrated)
            return LoadedExperience(document: doc, mediaResolver: BundleMediaResolver(), rootURL: url.deletingLastPathComponent())
        } catch {
            throw ExperienceLoaderError.malformedDocument(reason: String(describing: error))
        }
    }
}
