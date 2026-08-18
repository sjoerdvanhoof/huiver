import Foundation

/// One message on the wire.
///
/// Two kinds and nothing else. Control frames are JSON and describe what is
/// about to happen; blob frames are the bytes of a file being handed over. They
/// are kept apart so that a megabyte of audio never has to be base64'd into a
/// JSON document, which would cost a third again in size and a copy of the
/// whole thing in memory at both ends.
public struct Frame: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case control = 1
        case blob = 2
    }

    public let kind: Kind
    public let payload: Data

    public init(kind: Kind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

/// Length-prefixed framing over a byte stream.
///
/// TCP has no message boundaries — a `receive` can return half a frame, or two
/// and a half — so the length has to be on the wire. This is hand-rolled rather
/// than `NWProtocolFramer` because it is twenty lines, it can be unit-tested
/// without a network, and when something goes wrong the bytes are right here to
/// look at.
///
/// ```
/// u32 length (little-endian, payload only) | u8 kind | payload
/// ```
public enum Framing {
    /// Header: four bytes of length, one of kind.
    public static let headerSize = 5

    /// The largest frame that will be read.
    ///
    /// A blob is sent in chunks well under this; anything claiming to be bigger
    /// is a garbled stream or a peer that should not be trusted, and allocating
    /// what it asks for is how a bad length becomes an out-of-memory crash.
    public static let maxPayload = 8 * 1024 * 1024

    public enum FramingError: Error, LocalizedError, Equatable {
        case oversizedFrame(Int)
        case unknownKind(UInt8)

        public var errorDescription: String? {
            switch self {
            case .oversizedFrame(let size):
                return "The other device sent a \(size)-byte frame, which is too large to be real."
            case .unknownKind(let kind):
                return "The other device sent a frame of an unknown kind (\(kind))."
            }
        }
    }

    public static func encode(_ frame: Frame) -> Data {
        var out = Data(capacity: headerSize + frame.payload.count)
        var length = UInt32(frame.payload.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(frame.kind.rawValue)
        out.append(frame.payload)
        return out
    }
}

/// Turns a stream of arbitrary byte runs into whole frames.
///
/// Feed it whatever arrives; take whatever is complete. It holds the remainder
/// between calls, which is the entire point — the boundaries of what comes off
/// the socket have nothing to do with the boundaries of what was sent.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append received bytes and return every frame now complete.
    public mutating func push(_ bytes: Data) throws -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []

        while buffer.count >= Framing.headerSize {
            let length = Int(buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(as: UInt32.self).littleEndian
            })
            guard length <= Framing.maxPayload else {
                throw Framing.FramingError.oversizedFrame(length)
            }
            let total = Framing.headerSize + length
            // The rest of this frame has not arrived yet. Keep what we have and
            // wait to be pushed more.
            guard buffer.count >= total else { break }

            let rawKind = buffer[buffer.startIndex + 4]
            guard let kind = Frame.Kind(rawValue: rawKind) else {
                throw Framing.FramingError.unknownKind(rawKind)
            }
            let start = buffer.startIndex + Framing.headerSize
            frames.append(
                Frame(kind: kind, payload: Data(buffer[start..<(buffer.startIndex + total)]))
            )
            buffer.removeFirst(total)
        }
        return frames
    }

    /// Bytes held back because they are the beginning of a frame that has not
    /// finished arriving. Only interesting to tests and to a disconnect that
    /// wants to say whether it landed mid-message.
    public var pending: Int { buffer.count }
}

/// Somewhere to send frames and somewhere they come from.
///
/// `SyncSession` is written against this rather than against
/// `Network.framework` so that the whole protocol — handshake, manifest diff,
/// transfers, conflict resolution — can be tested over a pipe in the same
/// process, at full speed, with no permissions, no Bonjour and no second
/// device. The real transport is then a thin thing whose only job is bytes.
public protocol SyncTransport: Sendable {
    func send(_ frame: Frame) async throws
    /// The next frame, or nil when the other end has gone away.
    func receive() async throws -> Frame?
    func close() async
}
