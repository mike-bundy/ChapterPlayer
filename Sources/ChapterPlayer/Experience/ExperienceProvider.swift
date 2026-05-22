//
//  ExperienceProvider.swift
//  SharedVisions
//
//  Protocol-based loading for ChapterScript experience documents. Three
//  implementations are planned across phases:
//
//    LocalFolderExperienceProvider   — reads a `.chapterscript` directory bundle (this phase)
//    BundledExperienceProvider       — reads an experience.json from the app bundle (this phase)
//    LiveDevExperienceProvider       — Bonjour + HTTP client to MaestroStudio  (Phase 5)
//
//  Background Assets-backed media resolution is folded in at the resolver level
//  (Phase 6), not here.
//

import Foundation
import ChapterScript

public struct LoadedExperience: Sendable {
    public let document: ExperienceDocument
    public let mediaResolver: MediaResolver
    /// On-disk root the experience was loaded from. `nil` for synthetic / in-memory loads.
    public let rootURL: URL?
}

public enum ExperienceLoaderError: Error, CustomStringConvertible {
    case missingDocument(String)
    case malformedDocument(reason: String)
    case unreadable(URL, underlying: Error)

    public var description: String {
        switch self {
        case .missingDocument(let path):
            return "experience.json not found at \(path)"
        case .malformedDocument(let reason):
            return "Malformed experience document: \(reason)"
        case .unreadable(let url, let err):
            return "Could not read experience at \(url.path): \(err.localizedDescription)"
        }
    }
}

public protocol ExperienceProvider: Sendable {
    func load() async throws -> LoadedExperience
}

// MARK: - Local folder

/// Loads a `.chapterscript` directory bundle from any URL on disk. The directory
/// is expected to contain `experience.json` plus an optional `assets/` subfolder.
public struct LocalFolderExperienceProvider: ExperienceProvider {
    public let folderURL: URL

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    public func load() async throws -> LoadedExperience {
        let docURL = folderURL.appending(path: ChapterScriptFormat.documentFileName)
        guard FileManager.default.fileExists(atPath: docURL.path()) else {
            throw ExperienceLoaderError.missingDocument(docURL.path())
        }

        let data: Data
        do {
            data = try Data(contentsOf: docURL)
        } catch {
            throw ExperienceLoaderError.unreadable(docURL, underlying: error)
        }

        let document: ExperienceDocument
        do {
            // Run any pending JSON migrations forward to the current format version.
            let migrated = try Migrator.migrate(data)
            document = try ChapterScriptFormat.makeDecoder().decode(ExperienceDocument.self, from: migrated)
        } catch {
            throw ExperienceLoaderError.malformedDocument(reason: String(describing: error))
        }

        let assetsRoot = folderURL.appending(path: ChapterScriptFormat.assetsFolderName)
        let pathMap = Dictionary(
            uniqueKeysWithValues: document.manifest.entries.map { ($0.id, $0.relativePath) }
        )
        let resolver = LocalFolderMediaResolver(assetsRoot: assetsRoot, pathById: pathMap)
        return LoadedExperience(document: document, mediaResolver: resolver, rootURL: folderURL)
    }
}

// MARK: - App bundle

/// Loads a single `experience.json` from the app bundle. Handy for shipping a
/// canonical default experience without standing up a downloaded asset pack.
/// Media references are NOT resolved by this provider — they're expected to
/// fall back to the existing manager-side bundle search.
public struct BundledExperienceProvider: ExperienceProvider {
    /// Resource name (without extension). Defaults to "experience".
    public let resourceName: String
    /// Optional subdirectory inside the bundle, e.g. "Experiences/colorDrift.chapterscript".
    public let subdirectory: String?
    /// Bundle to search. Defaults to `Bundle.main`.
    public let bundle: Bundle

    public init(resourceName: String = "experience", subdirectory: String? = nil, bundle: Bundle = .main) {
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
            let doc = try ChapterScriptFormat.makeDecoder().decode(ExperienceDocument.self, from: migrated)
            return LoadedExperience(document: doc, mediaResolver: BundleMediaResolver(), rootURL: url.deletingLastPathComponent())
        } catch {
            throw ExperienceLoaderError.malformedDocument(reason: String(describing: error))
        }
    }
}
