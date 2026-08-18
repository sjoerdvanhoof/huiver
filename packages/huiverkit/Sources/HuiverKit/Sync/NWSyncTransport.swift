import Foundation
import Network

/// `SyncTransport` over a live `NWConnection`.
///
/// The thin layer the tests do not cover, kept thin for exactly that reason:
/// its whole job is moving bytes between the connection and `FrameDecoder`.
/// Everything with logic in it — the protocol, the diff, the hashes — runs
/// above this seam and is tested over a pipe.
public actor NWSyncTransport: SyncTransport {
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var buffered: [Frame] = []

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ frame: Frame) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Framing.encode(frame),
                completion: .contentProcessed { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            )
        }
    }

    public func receive() async throws -> Frame? {
        // Frames already decoded from a previous read that carried more than
        // one of them.
        if !buffered.isEmpty { return buffered.removeFirst() }

        while true {
            let (data, isComplete) = try await read()
            if let data, !data.isEmpty {
                let frames = try decoder.push(data)
                if let first = frames.first {
                    buffered.append(contentsOf: frames.dropFirst())
                    return first
                }
                // A read that completed a partial header but no whole frame:
                // keep reading.
            }
            if isComplete { return nil }
        }
    }

    private func read() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 256 * 1024
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    public func close() async {
        connection.cancel()
    }
}

/// Wait for an `NWConnection` to become ready, or fail with why it did not.
///
/// Local-network permission denial never arrives as an error — the connection
/// just sits in `.waiting` forever — so readiness carries a timeout, and the
/// timeout's message points at the setting.
public enum NWReadiness {
    public enum ReadyError: Error, LocalizedError {
        case failed(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .failed(let why): return why
            case .timedOut:
                return """
                    Could not reach the other device. Check that local network access is \
                    allowed on both (Settings → Privacy & Security), that both apps are \
                    open, and that the pairing code is fresh — a stale or mismatched key \
                    looks exactly like this.
                    """
            }
        }
    }

    public static func waitUntilReady(
        _ connection: NWConnection, timeout: Duration = .seconds(15)
    ) async throws {
        let ready = AsyncStream<Result<Void, ReadyError>> { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.success(()))
                    continuation.finish()
                case .failed(let error):
                    continuation.yield(.failure(.failed(error.localizedDescription)))
                    continuation.finish()
                case .cancelled:
                    continuation.yield(.failure(.failed("The connection was cancelled.")))
                    continuation.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        let outcome = await withTaskGroup(of: Result<Void, ReadyError>?.self) { group in
            group.addTask {
                for await result in ready { return result }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(.timedOut)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        switch outcome {
        case .success:
            return
        case .failure(let error):
            connection.cancel()
            throw error
        case nil:
            connection.cancel()
            throw ReadyError.timedOut
        }
    }
}
