//
//  LiveTransport.swift
//  SharedVisions
//
//  Wired-preferred transport selection for tethered live editing
//  (refactor-net phase 4). A Developer Strap presents itself as an
//  ethernet-over-USB interface; when one is present and the Mac's live
//  server is reachable over it, low-latency control traffic (ops, SSE,
//  save) takes the wire. Bulk asset traffic takes whichever path wins a
//  short raced probe, because a gen-1 strap (~100 Mbps) can lose to good
//  WiFi while a gen-2 strap beats it.
//
//  URLSession cannot be interface-steered directly; the sanctioned
//  pattern is dual-dial: resolve the SAME Bonjour service over a
//  wired-constrained NWConnection, then talk to the interface-scoped
//  address it yields (a link-local IPv6 literal with a zone id is only
//  reachable over that interface, which is the steering).
//

import Foundation
import Network
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.shellcorp.sharedvisions",
    category: "LiveTransport"
)

/// The resolved pair of base URLs a tethered session should use, plus
/// whether a verified wired link backs the control path.
///
/// `controlBaseURL` carries ops, SSE, saves, and the document fetch.
/// `assetBaseURL` carries bulk media transfer; `nil` means "use the
/// control URL" (no distinct bulk path won the probe).
public struct LiveTransport: Sendable {
    public let controlBaseURL: URL
    public let assetBaseURL: URL?
    public let wiredAvailable: Bool

    public init(controlBaseURL: URL, assetBaseURL: URL?, wiredAvailable: Bool) {
        self.controlBaseURL = controlBaseURL
        self.assetBaseURL = assetBaseURL
        self.wiredAvailable = wiredAvailable
    }
}

/// Stateless helpers that pick the transport. Bounded at every step:
/// with no wired interface present the whole pass costs one path-monitor
/// gate (≤ 300 ms, usually immediate).
enum LiveTransportResolver {

    /// Full selection pass. `unconstrainedBaseURL` is the ordinary
    /// Bonjour-resolved URL (WiFi/AWDL); `endpoint` is the same service's
    /// NWEndpoint for the wired-constrained dial.
    static func resolve(
        unconstrainedBaseURL: URL,
        endpoint: NWEndpoint?
    ) async -> LiveTransport {
        let fallback = LiveTransport(
            controlBaseURL: unconstrainedBaseURL,
            assetBaseURL: nil,
            wiredAvailable: false
        )
        guard let endpoint else { return fallback }
        guard await wiredPathExists(gate: .milliseconds(300)) else { return fallback }
        guard let wired = try? await resolveWiredBaseURL(endpoint: endpoint, patience: .seconds(1.5)) else {
            logger.info("Wired interface present but service not reachable over it; staying on WiFi")
            return fallback
        }
        guard await verify(baseURL: wired, timeout: 2.0) else {
            logger.info("Wired candidate \(wired.absoluteString, privacy: .public) failed HEAD verification")
            return fallback
        }
        logger.info("Wired control path verified: \(wired.absoluteString, privacy: .public)")
        // Bulk stays undecided here — the caller races a ranged probe once
        // it knows the largest asset, then fills `assetBaseURL`.
        return LiveTransport(controlBaseURL: wired, assetBaseURL: nil, wiredAvailable: true)
    }

    /// Race a 4 MB ranged read of the project's largest asset over the
    /// wired and unconstrained paths. Returns the base URL bulk traffic
    /// should use. WiFi wins ties and failures — the wire must PROVE it
    /// is faster before bulk moves off the radio.
    static func raceBulkProbe(
        wiredBaseURL: URL,
        unconstrainedBaseURL: URL,
        assetRelativePath: String
    ) async -> URL {
        let path = "assets/\(assetRelativePath)"
        async let wiredTime = timedRangedFetch(base: wiredBaseURL, path: path)
        async let wifiTime = timedRangedFetch(base: unconstrainedBaseURL, path: path)
        let (wired, wifi) = await (wiredTime, wifiTime)
        switch (wired, wifi) {
        case (.some(let w), .some(let f)) where w < f:
            logger.info("Bulk probe: wire \(String(format: "%.2f", w))s beats WiFi \(String(format: "%.2f", f))s")
            return wiredBaseURL
        case (.some(let w), nil):
            logger.info("Bulk probe: WiFi failed, wire answered in \(String(format: "%.2f", w))s")
            return wiredBaseURL
        default:
            return unconstrainedBaseURL
        }
    }

    // MARK: - Steps

    /// Does ANY wired path exist right now? One-shot NWPathMonitor gate.
    private static func wiredPathExists(gate: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
                    let resumer = BoolOnceResumer(continuation: continuation) { monitor.cancel() }
                    monitor.pathUpdateHandler = { path in
                        resumer.resume(path.status == .satisfied)
                    }
                    monitor.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try? await Task.sleep(for: gate)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Dial the same Bonjour service constrained to wired ethernet and
    /// read back the interface-scoped host:port it resolves to.
    private static func resolveWiredBaseURL(
        endpoint: NWEndpoint,
        patience: Duration
    ) async throws -> URL {
        let resolved: (host: String, port: UInt16) = try await withCheckedThrowingContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            parameters.requiredInterfaceType = .wiredEthernet
            let connection = NWConnection(to: endpoint, using: parameters)
            let resumer = HostPortOnceResumer(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       let remote = path.remoteEndpoint,
                       case .hostPort(let host, let port) = remote {
                        resumer.resume(.success((hostString(for: host), port.rawValue)))
                    } else {
                        resumer.resume(.failure(ExperienceLoaderError.malformedDocument(reason: "No wired host/port")))
                    }
                case .failed(let err):
                    resumer.resume(.failure(err))
                case .cancelled:
                    resumer.resume(.failure(ExperienceLoaderError.malformedDocument(reason: "Wired resolve cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // Patience cap: a wired interface with no listening peer hangs
            // in .preparing forever — cancel turns that into .cancelled.
            Task {
                try? await Task.sleep(for: patience)
                connection.cancel()
            }
        }
        guard let url = URL(string: "http://\(resolved.host):\(resolved.port)") else {
            throw ExperienceLoaderError.malformedDocument(reason: "Couldn't build wired URL from \(resolved)")
        }
        return url
    }

    /// HEAD `/chapter.json` — proves an actual Maestro live server answers
    /// on this path, not merely that a socket opened.
    private static func verify(baseURL: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "chapter.json"))
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Fetch the first 4 MB of an asset and report elapsed seconds; nil on
    /// any failure. Generous timeout — the race decides, not the timeout.
    private static func timedRangedFetch(base: URL, path: String) async -> TimeInterval? {
        var request = URLRequest(url: base.appending(path: path))
        request.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = ContinuousClock.now
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) || http.statusCode == 206 else { return nil }
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) / 1e18
    }
}

/// Format an NWEndpoint.Host as a URL host component. Link-local IPv6
/// addresses carry a zone id (`fe80::1%en5`); the `%` must be
/// percent-encoded (`%25`) to form a valid URL, and keeping the zone is
/// the POINT — it is what steers traffic onto that interface.
func hostString(for host: NWEndpoint.Host) -> String {
    switch host {
    case .name(let s, _):
        return s
    case .ipv4(let v4):
        return "\(v4)"
    case .ipv6(let v6):
        let raw = "\(v6)"
        let zoned = raw.replacingOccurrences(of: "%", with: "%25")
        return "[\(zoned)]"
    @unknown default:
        return "localhost"
    }
}

// MARK: - Once-only resumers

/// Resume a Bool continuation exactly once, running `onFirst` (monitor
/// cancel) on the first fire.
private final class BoolOnceResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let onFirst: @Sendable () -> Void
    private let lock = NSLock()
    private var fired = false

    init(continuation: CheckedContinuation<Bool, Never>, onFirst: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onFirst = onFirst
    }

    func resume(_ value: Bool) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        lock.unlock()
        onFirst()
        continuation.resume(returning: value)
    }
}

/// Same once-only contract as the provider's OnceResumer, kept private to
/// this file so the two cannot drift into shared mutable state.
private final class HostPortOnceResumer: @unchecked Sendable {
    private let continuation: CheckedContinuation<(host: String, port: UInt16), Error>
    private let connection: NWConnection
    private let lock = NSLock()
    private var fired = false

    init(
        continuation: CheckedContinuation<(host: String, port: UInt16), Error>,
        connection: NWConnection
    ) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Result<(String, UInt16), Error>) {
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
