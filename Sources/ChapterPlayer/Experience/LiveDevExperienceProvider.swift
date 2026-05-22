//
//  LiveDevExperienceProvider.swift
//  SharedVisions
//
//  Phase 5: discovers a MaestroStudio instance on the LAN via Bonjour
//  (`_maestro._tcp`), fetches the current `ExperienceDocument` over HTTP,
//  and (when subscribed) hot-reloads on Server-Sent Events.
//
//  Network framework only — no third-party dependency.
//

import Foundation
import Network
import OSLog
import Combine
import ChapterScript

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "Live"
)

// MARK: - Discovered service

public struct LiveServerDescriptor: Hashable, Identifiable, Sendable {
    /// Bonjour service name as advertised by Maestro (e.g., "Maestro on Vlad's MacBook").
    public let serviceName: String
    /// `_maestro._tcp` typically; kept on the descriptor in case we add other types.
    public let serviceType: String
    /// Resolved host:port endpoint. Filled in by `LiveServerBrowser` after a resolve pass.
    public let endpoint: NWEndpoint?

    public var id: String { "\(serviceName)|\(serviceType)" }
}

// MARK: - Browser

/// Listens for `_maestro._tcp` Bonjour advertisements and publishes the current
/// list of services to SwiftUI observers.
@MainActor
public final class LiveServerBrowser: ObservableObject {

    public init() {}
    @Published private(set) public var services: [LiveServerDescriptor] = []
    @Published private(set) public var error: String?

    private var browser: NWBrowser?

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_maestro._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err):
                Task { @MainActor [weak self] in
                    self?.error = "Browser failed: \(err.localizedDescription)"
                }
            case .ready:
                Task { @MainActor [weak self] in self?.error = nil }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        services = []
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var found: [LiveServerDescriptor] = []
        for result in results {
            if case .service(let name, let type, _, _) = result.endpoint {
                found.append(LiveServerDescriptor(
                    serviceName: name,
                    serviceType: type,
                    endpoint: result.endpoint
                ))
            }
        }
        services = found.sorted { $0.serviceName < $1.serviceName }
    }
}

// MARK: - Provider

/// Loads an `ExperienceDocument` from a discovered MaestroStudio instance over
/// HTTP. Optionally subscribes to the SSE stream for hot-reload.
public struct LiveDevExperienceProvider: ExperienceProvider {
    public let descriptor: LiveServerDescriptor
    /// Optional progress sink for the asset prefetch pass. UI binds to this so
    /// authors see "streaming N/M" while the player pulls files from the Mac.
    public let prefetchProgress: LivePrefetchProgress?

    public init(descriptor: LiveServerDescriptor, prefetchProgress: LivePrefetchProgress? = nil) {
        self.descriptor = descriptor
        self.prefetchProgress = prefetchProgress
    }

    public func load() async throws -> LoadedExperience {
        let baseURL = try await resolveBaseURL()
        let docURL = baseURL.appending(path: "experience.json")
        var request = URLRequest(url: docURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let document: ExperienceDocument
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ExperienceLoaderError.malformedDocument(reason: "HTTP \(code) from \(docURL.path())")
            }
            let migrated = try Migrator.migrate(data)
            document = try ChapterScriptFormat.makeDecoder().decode(ExperienceDocument.self, from: migrated)
        } catch let err as ExperienceLoaderError {
            throw err
        } catch {
            throw ExperienceLoaderError.unreadable(docURL, underlying: error)
        }

        // Phase 5.1: pull every audio / USDZ / image asset from the editor
        // into a local cache. Videos stay on the streaming URL — AVPlayer will
        // Range-fetch them lazily.
        let resolver: MediaResolver
        if !document.manifest.entries.isEmpty {
            do {
                resolver = try await LiveMediaResolver.prefetch(
                    manifest: document.manifest,
                    serverBaseURL: baseURL,
                    cacheRoot: LiveMediaResolver.defaultCacheRoot(),
                    progress: prefetchProgress
                )
            } catch {
                logger.warning("LiveMediaResolver.prefetch failed: \(error.localizedDescription); falling back to bundle resolver")
                resolver = BundleMediaResolver()
            }
        } else {
            // Empty manifest — likely a brand-new Untitled project. Fall back
            // to the bundle resolver so existing static assets still work.
            resolver = BundleMediaResolver()
        }

        return LoadedExperience(
            document: document,
            mediaResolver: resolver,
            rootURL: baseURL
        )
    }

    /// Resolve the discovered Bonjour endpoint to a concrete `http://host:port` URL.
    /// `URLSession` can't dial NWEndpoint directly, so we use NWConnection just
    /// long enough to learn the IPv4/IPv6 host and port the service is bound to.
    private func resolveBaseURL() async throws -> URL {
        guard let endpoint = descriptor.endpoint else {
            throw ExperienceLoaderError.malformedDocument(reason: "No endpoint for service")
        }

        let resolved: (host: String, port: UInt16) = try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: parameters)

            // Wrap the once-only resume in a Sendable box so the
            // @Sendable state-update handler can fire it without the
            // strict-concurrency checker flagging captures.
            let resumer = OnceResumer(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       let endpoint = path.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostString: String
                        switch host {
                        case .name(let s, _):           hostString = s
                        case .ipv4(let v4):             hostString = "\(v4)"
                        case .ipv6(let v6):             hostString = "[\(v6)]"
                        @unknown default:               hostString = "localhost"
                        }
                        resumer.resume(.success((hostString, port.rawValue)))
                    } else {
                        resumer.resume(.failure(ExperienceLoaderError.malformedDocument(reason: "Could not extract host/port")))
                    }
                case .failed(let err):
                    resumer.resume(.failure(err))
                case .cancelled:
                    resumer.resume(.failure(ExperienceLoaderError.malformedDocument(reason: "Resolve cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }

        guard let url = URL(string: "http://\(resolved.host):\(resolved.port)") else {
            throw ExperienceLoaderError.malformedDocument(reason: "Couldn't build URL from \(resolved)")
        }
        return url
    }
}

// MARK: - SSE subscription (hot-reload)

/// Subscribe to the live server's `/events` stream. Calls `onChanged` whenever
/// MaestroStudio reports a `doc-changed` event. Lives on its own task; cancel
/// the returned `LiveSubscription` to unsubscribe.
@MainActor
public final class LiveSubscription {
    private var task: Task<Void, Never>?

    public init(descriptor: LiveServerDescriptor, onChanged: @MainActor @escaping () -> Void) {
        self.task = Task { [weak self] in
            await self?.run(descriptor: descriptor, onChanged: onChanged)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(
        descriptor: LiveServerDescriptor,
        onChanged: @MainActor @escaping () -> Void
    ) async {
        // Resolve once via the same path the provider uses, then stream lines.
        let provider = LiveDevExperienceProvider(descriptor: descriptor)
        guard let baseURL = try? await provider.resolveBaseURLPublic() else {
            logger.warning("LiveSubscription: could not resolve endpoint")
            return
        }

        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            let url = baseURL.appending(path: "events")
            var request = URLRequest(url: url)
            request.timeoutInterval = .infinity
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    logger.warning("SSE status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                logger.info("SSE connected to \(descriptor.serviceName, privacy: .public)")
                attempt = 0
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("event: doc-changed") {
                        await MainActor.run { onChanged() }
                    }
                }
            } catch {
                if Task.isCancelled { break }
                logger.warning("SSE error (attempt \(attempt)): \(error.localizedDescription)")
                let backoff = min(pow(1.5, Double(attempt)), 10)
                try? await Task.sleep(for: .seconds(backoff))
            }
        }
    }
}

// Expose the resolver to LiveSubscription without leaking the privacy of the
// internal helper. Same logic, different access level.
extension LiveDevExperienceProvider {
    public func resolveBaseURLPublic() async throws -> URL {
        try await resolveBaseURL()
    }
}

/// Internal helper: resumes a `CheckedContinuation` exactly once and
/// cancels the NWConnection on first resume. Lock-guarded so the
/// NWConnection state-update handler (a @Sendable closure) can call
/// `resume(_:)` from any network queue without violating the
/// continuation's once-only contract.
private final class OnceResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<(host: String, port: UInt16), Error>
    private let connection: NWConnection
    private let lock = NSLock()
    private var fired = false

    public init(
        continuation: CheckedContinuation<(host: String, port: UInt16), Error>,
        connection: NWConnection
    ) {
        self.continuation = continuation
        self.connection = connection
    }

    public func resume(_ result: Result<(String, UInt16), Error>) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        lock.unlock()
        connection.cancel()
        switch result {
        case .success(let pair): continuation.resume(returning: pair)
        case .failure(let err):  continuation.resume(throwing: err)
        }
    }
}
