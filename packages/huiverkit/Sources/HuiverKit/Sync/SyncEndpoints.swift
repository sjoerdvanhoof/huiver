import Foundation
import Network

/// The Mac's side of the wire: advertise on Bonjour, accept connections, run a
/// server session over each.
///
/// Two modes, one listener each. In *pairing* mode the listener accepts the
/// ephemeral QR secret and a successful session ends with both sides storing a
/// long-term key. In *paired* mode it accepts any already-paired phone, looked
/// up by the PSK identity the phone presents — which is its device id, so the
/// right key can be chosen before the handshake completes.
public final class SyncServer: @unchecked Sendable {
    public typealias MakeSession = @Sendable (NWSyncTransport) async -> Void

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "huiver.sync.server")

    public init() {}

    /// Advertise and accept connections with one pre-shared key.
    ///
    /// The caller owns what a connection *means* — pairing exchange or full
    /// sync session — this only owns sockets.
    public func start(
        serviceName: String,
        psk: Data,
        pskIdentity: String,
        onConnection: @escaping MakeSession
    ) throws {
        stop()
        let parameters = SyncTLS.parameters(psk: psk, identity: pskIdentity)
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: serviceName, type: SyncProtocol.serviceType)
        // The listener fails asynchronously or not at all — a Bonjour name
        // conflict, for instance, when a new listener reuses the name of one
        // that was cancelled a moment ago and has not left mDNS yet. Nobody
        // sees that without watching the state, which is precisely how the Mac
        // spent an evening paired but unreachable. A failed listener is retried
        // once after the old registration has had time to clear.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                PlaybackLog.note(
                    "sync: listening as \(serviceName), key for identity "
                        + "\(pskIdentity.prefix(13))… (\(psk.count)B, \(psk.prefix(4).map { String(format: "%02x", $0) }.joined()))"
                )
            case .failed(let error):
                PlaybackLog.note("sync: listener failed: \(error.localizedDescription)")
                listener?.cancel()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.listener == nil || self.listener === listener else {
                        return
                    }
                    PlaybackLog.note("sync: retrying the listener")
                    try? self.start(
                        serviceName: serviceName, psk: psk, pskIdentity: pskIdentity,
                        onConnection: onConnection
                    )
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            Task {
                do {
                    try await NWReadiness.waitUntilReady(connection)
                    await onConnection(NWSyncTransport(connection: connection))
                } catch {
                    // A phone with a stale key fails its handshake here. That is
                    // the unpair story working, not a server problem.
                    PlaybackLog.note("sync: inbound connection failed: \(error.localizedDescription)")
                    connection.cancel()
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// The phone's side: find the Mac on Bonjour and connect to it.
public enum SyncClient {
    public enum ClientError: Error, LocalizedError {
        case notFound(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return """
                    Could not find \(name) on the network. Make sure huiver is open on the \
                    Mac and both devices are on the same Wi-Fi.
                    """
            }
        }
    }

    /// Browse until the named service appears, then hand back its endpoint.
    ///
    /// Connecting to the *endpoint* rather than a resolved address matters:
    /// Bonjour re-resolves at connect time, so a Mac whose DHCP lease rolled
    /// over since pairing is still found.
    public static func find(
        serviceName: String, timeout: Duration = .seconds(10)
    ) async throws -> NWEndpoint {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: SyncProtocol.serviceType, domain: nil), using: parameters
        )

        let found = AsyncStream<NWEndpoint> { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint, name == serviceName {
                        continuation.yield(result.endpoint)
                        continuation.finish()
                        return
                    }
                }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        defer { browser.cancel() }

        return try await withThrowingTaskGroup(of: NWEndpoint?.self) { group in
            group.addTask {
                for await endpoint in found { return endpoint }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            guard let endpoint = try await group.next() ?? nil else {
                group.cancelAll()
                throw ClientError.notFound(serviceName)
            }
            group.cancelAll()
            return endpoint
        }
    }

    /// Open a TLS-PSK connection to an endpoint found by `find`.
    public static func connect(
        to endpoint: NWEndpoint, psk: Data, pskIdentity: String
    ) async throws -> NWSyncTransport {
        let connection = NWConnection(
            to: endpoint, using: SyncTLS.parameters(psk: psk, identity: pskIdentity)
        )
        try await NWReadiness.waitUntilReady(connection)
        return NWSyncTransport(connection: connection)
    }
}
