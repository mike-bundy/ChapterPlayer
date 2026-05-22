//
//  LiveMediaResolver.swift
//  SharedVisions
//
//  Phase 5.1: when a live experience is loaded, fetches every entry in the
//  document's `AssetManifest` from the MaestroStudio HTTP server and caches
//  them locally. Audio / USDZ / images need on-disk URLs because their
//  loaders (AVAudioFile, Entity.load(contentsOf:), UIImage) don't speak HTTP
//  off the bat. Video can stream directly via AVPlayer, so the resolver
//  returns the live HTTP URL for `.video` entries.
//

import Foundation
import OSLog
import Combine
import CryptoKit
import ChapterScript

private let mediaLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "LiveMedia"
)

/// Tracks per-asset prefetch progress so the UI can surface a "loading 3/12"
/// indicator + a smooth progress bar while the player is pulling files from
/// the Mac. Bytes flow in continuously during each download — the fraction
/// is derived from `transferredBytes / totalBytes` so the bar moves the
/// whole time, not just when a file completes.
@MainActor
public final class LivePrefetchProgress: ObservableObject {

    public init() {}
    @Published public var totalCount: Int = 0
    @Published public var completedCount: Int = 0
    @Published public var totalBytes: Int64 = 0
    @Published public var transferredBytes: Int64 = 0
    @Published public var lastError: String?
    /// Rolling bytes-per-second readout for the loading overlay. Sampled
    /// every ~500ms by `recordSpeedSample(...)` below.
    @Published public var bytesPerSecond: Double = 0

    private var lastSampleTime: Date?
    private var lastSampleBytes: Int64 = 0

    public var isPrefetching: Bool { completedCount < totalCount }

    /// Byte-based progress fraction so the bar advances smoothly during
    /// each download, not just at file boundaries. Falls back to the
    /// count-based fraction when totalBytes is unknown.
    public var fraction: Double {
        if totalBytes > 0 {
            return min(1.0, Double(transferredBytes) / Double(totalBytes))
        }
        guard totalCount > 0 else { return 1 }
        return Double(completedCount) / Double(totalCount)
    }

    public func reset(totalCount: Int, totalBytes: Int64) {
        self.totalCount = totalCount
        self.completedCount = 0
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.bytesPerSecond = 0
        self.lastSampleTime = nil
        self.lastSampleBytes = 0
        self.lastError = nil
    }

    /// Record bytes downloaded in a single chunk. Called repeatedly
    /// during each file's transfer.
    public func addBytes(_ bytes: Int64) {
        transferredBytes += bytes
        recordSpeedSample()
    }

    /// Mark a file as completed (separate from byte accounting so we can
    /// surface "3/12 files done" alongside the byte-level bar).
    public func markCompleted() {
        completedCount += 1
    }

    private func recordSpeedSample() {
        let now = Date()
        if let last = lastSampleTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0.5 {
                let delta = transferredBytes - lastSampleBytes
                bytesPerSecond = Double(delta) / elapsed
                lastSampleTime = now
                lastSampleBytes = transferredBytes
            }
        } else {
            lastSampleTime = now
            lastSampleBytes = transferredBytes
        }
    }
}

/// Caches HTTP-fetched assets so audio/USDZ/images can be loaded as if local.
/// Video files keep their HTTP URL — AVPlayer streams them with Range requests
/// against the LiveServer.
public struct LiveMediaResolver: MediaResolver {

    /// Resolved base URL for `/assets/<path>` lookups (e.g., http://192.168.1.5:54123).
    public let serverBaseURL: URL

    /// id → local file URL for cached audio / USDZ / image entries.
    public let cachedURLByID: [String: URL]

    /// id → server URL for video entries (and anything we chose to stream).
    public let streamingURLByID: [String: URL]

    public func url(for assetId: String, kind: MediaKind) -> URL? {
        // Try exact id match first.
        if let cached = cachedURLByID[assetId] { return cached }
        if let streaming = streamingURLByID[assetId] { return streaming }

        // Fuzzy: callers often pass the file field minus extension. Fall back
        // to matching on basename without extension.
        let stem = (assetId as NSString).deletingPathExtension
        if let match = cachedURLByID.first(where: { ($0.key as NSString).deletingPathExtension == stem }) {
            return match.value
        }
        if let match = streamingURLByID.first(where: { ($0.key as NSString).deletingPathExtension == stem }) {
            return match.value
        }
        return nil
    }

    /// Build a resolver from a freshly-loaded live document by prefetching
    /// **every** referenced asset into the local cache — including video.
    ///
    /// Earlier revisions kept video as a streaming URL on the assumption
    /// that AVPlayer's HTTP range requests would handle large files
    /// gracefully. In practice, even after preroll + first-frame warmup,
    /// AVPlayer over the LAN to MaestroStudio's NWListener-based server
    /// still introduces a multi-second first-frame delay at chapter step
    /// time. The author's expectation is sub-frame timing accuracy, so
    /// we now download videos to disk too and play from the local file
    /// URL. The loading overlay already binds to `LivePrefetchProgress`
    /// so the user sees a real progress bar covering the heavy bytes.
    ///
    /// `streamingURLByID` is retained on the resolver as a fallback for
    /// videos whose download fails (e.g., transient network blip on a
    /// huge file). `url(for:)` returns the cached URL when present and
    /// falls back to the streaming URL otherwise.
    ///
    /// - parameter manifest: the loaded `AssetManifest`.
    /// - parameter cacheRoot: typically `~/Library/Caches/SharedVisions/Live/`.
    /// - parameter progress: optional progress sink for UI binding.
    static public func prefetch(
        manifest: AssetManifest,
        serverBaseURL: URL,
        cacheRoot: URL,
        progress: LivePrefetchProgress?
    ) async throws -> LiveMediaResolver {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        // Phase 5.5: every kind is downloaded. Videos used to stream.
        let downloadable = manifest.entries

        let totalBytes: Int64 = downloadable.reduce(0) { $0 + ($1.byteSize ?? 0) }
        await MainActor.run {
            progress?.reset(totalCount: downloadable.count, totalBytes: totalBytes)
        }

        // Concurrent downloads. Capped at 4 simultaneous tasks because:
        //   - Each adds a TCP connection to the same LiveServer process
        //     (NWListener handles them fine but per-connection
        //     throughput is gated by the Mac's disk + the LAN).
        //   - Vision Pro has finite disk write bandwidth; too many
        //     parallel writes starve each other.
        //   - 4 is empirically enough to saturate a typical 100Mbps
        //     LAN while leaving the system responsive.
        let maxConcurrent = 4

        // Concurrency-safe accumulators — populated as each task
        // returns, drained outside the group.
        var cached: [String: URL] = [:]
        var streamingMap: [String: URL] = [:]

        try await withThrowingTaskGroup(of: DownloadResult.self) { group in
            var iterator = downloadable.makeIterator()
            var inFlight = 0

            // Seed the group with up to maxConcurrent tasks.
            while inFlight < maxConcurrent, let entry = iterator.next() {
                let url = serverBaseURL.appending(path: "assets").appending(path: entry.relativePath)
                group.addTask {
                    await Self.attemptDownload(entry: entry, from: url, into: cacheRoot, progress: progress)
                }
                inFlight += 1
            }

            // Drain + refill — every time a task finishes we kick off
            // the next pending one, keeping a steady inFlight pipeline.
            while let result = try await group.next() {
                inFlight -= 1
                switch result {
                case .success(let id, let url):
                    cached[id] = url
                case .failure(let id, let streamingURL, _):
                    if let streamingURL { streamingMap[id] = streamingURL }
                }
                await MainActor.run { progress?.markCompleted() }
                if let entry = iterator.next() {
                    let url = serverBaseURL.appending(path: "assets").appending(path: entry.relativePath)
                    group.addTask {
                        await Self.attemptDownload(entry: entry, from: url, into: cacheRoot, progress: progress)
                    }
                    inFlight += 1
                }
            }
        }

        return LiveMediaResolver(
            serverBaseURL: serverBaseURL,
            cachedURLByID: cached,
            streamingURLByID: streamingMap
        )
    }

    /// Wrapper that runs `downloadIfNeeded` and translates errors into
    /// a streaming-URL fallback so a single failing file doesn't kill
    /// the whole prefetch. Returns a `DownloadResult` for the caller's
    /// dispatch loop.
    private static func attemptDownload(
        entry: AssetEntry,
        from url: URL,
        into cacheRoot: URL,
        progress: LivePrefetchProgress?
    ) async -> DownloadResult {
        do {
            let cached = try await downloadIfNeeded(entry: entry, from: url, into: cacheRoot, progress: progress)
            return .success(id: entry.id, url: cached)
        } catch {
            mediaLogger.warning("prefetch failed for \(entry.id): \(error.localizedDescription); will stream as fallback")
            // SHA-prefixed cache-buster so AVPlayer treats post-edit
            // files as fresh assets.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let sha = entry.sha256 {
                components?.queryItems = [URLQueryItem(name: "v", value: String(sha.prefix(12)))]
            }
            await MainActor.run {
                progress?.lastError = "Could not fetch \(entry.id): \(error.localizedDescription)"
            }
            return .failure(id: entry.id, streamingURL: components?.url, error: error)
        }
    }

    private enum DownloadResult {
        case success(id: String, url: URL)
        case failure(id: String, streamingURL: URL?, error: Error)
    }

    /// Cache layout: `<cacheRoot>/<sha256-prefix-or-pathHash>/<basename>`.
    /// The prefix lets us namespace by content so re-saves of the same file
    /// hit the cache without re-downloading.
    ///
    /// Downloads a single asset to the cache, reporting incremental
    /// byte-level progress along the way.
    ///
    /// The previous revision streamed `URLSession.bytes(for:)` one byte at
    /// a time, which forced an `await` suspension per byte — for a 1GB
    /// AIVU that's a *billion* context switches and capped throughput at
    /// ~100 KB/s on visionOS. We now drive a delegate-based download
    /// task: `URLSession` writes the body to a temp file at the OS's
    /// native speed, and `urlSession(_:downloadTask:didWriteData:...)`
    /// fires the progress updates.
    private static func downloadIfNeeded(
        entry: AssetEntry,
        from url: URL,
        into cacheRoot: URL,
        progress: LivePrefetchProgress?
    ) async throws -> URL {
        let bucket = entry.sha256 ?? hashPath(entry.relativePath)
        let bucketPrefix = String(bucket.prefix(8))
        let bucketDir = cacheRoot.appendingPathComponent(bucketPrefix)
        try FileManager.default.createDirectory(at: bucketDir, withIntermediateDirectories: true)
        let basename = (entry.relativePath as NSString).lastPathComponent
        let dest = bucketDir.appendingPathComponent(basename)

        // Cache hit when sizes match (when SHA was the bucket key, contents
        // are guaranteed-equal too). Pretend the bytes were transferred so
        // the progress bar reflects the cache hit.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = (attrs[FileAttributeKey.size] as? NSNumber)?.int64Value,
           size == (entry.byteSize ?? size) {
            if let bytes = entry.byteSize {
                await MainActor.run { progress?.addBytes(bytes) }
            }
            return dest
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let tempURL = try await LivePrefetchDownloader.download(
            request: request,
            progress: progress
        )

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func hashPath(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Default cache root for the player.
    static public func defaultCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("SharedVisions/Live", isDirectory: true)
    }
}

/// `URLSessionDownloadTask` wrapper that reports per-write progress via the
/// `LivePrefetchProgress` sink and resumes the calling async function once
/// the download finishes (or fails).
///
/// Each instance owns its own `URLSession` so the delegate callbacks land
/// on a private queue. The instance is retained by the awaiting
/// continuation; once the task completes, the continuation resumes and the
/// downloader drops out of scope.
private final class LivePrefetchDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var progress: LivePrefetchProgress?
    private var continuation: CheckedContinuation<URL, Error>?

    static public func download(
        request: URLRequest,
        progress: LivePrefetchProgress?
    ) async throws -> URL {
        let downloader = LivePrefetchDownloader(progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // Plenty of headroom for our 1GB+ AIVU files on a slow LAN.
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            let session = URLSession(
                configuration: config,
                delegate: downloader,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    private init(progress: LivePrefetchProgress?) {
        self.progress = progress
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // `bytesWritten` is the delta for this callback; forward it as-is
        // so the @Published transferredBytes counter advances smoothly.
        let delta = bytesWritten
        guard delta > 0 else { return }
        let sink = progress
        Task { @MainActor in
            sink?.addBytes(delta)
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is a system-managed temp file that gets cleaned up
        // when this delegate method returns — move it into our own temp
        // directory before resuming the continuation.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // didFinishDownloadingTo handles the success path; this fires only
        // when the task fails OR after we've already handled it. Resume
        // with an error if we still have a live continuation.
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
