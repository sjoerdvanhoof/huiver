import Foundation

/// The short conversation that turns a scanned QR code into a stored pairing.
///
/// Runs over a connection already encrypted with the QR secret, so both sides
/// have proven themselves before a byte of this is exchanged. All that is left
/// is to swap identities and nonces and derive the key both will keep.
public enum PairingExchange {
    struct Request: Codable {
        var deviceId: String
        var deviceName: String
        var nonce: Data
    }

    struct Accept: Codable {
        var deviceId: String
        var deviceName: String
        var nonce: Data
    }

    /// The phone's half: introduce ourselves, hear who the Mac is, derive.
    public static func initiate(
        over transport: SyncTransport,
        pairingSecret: Data,
        deviceId: String,
        deviceName: String
    ) async throws -> PairingStore.Peer {
        let nonce = Pairing.makeSecret()
        let request = Request(deviceId: deviceId, deviceName: deviceName, nonce: nonce)
        try await transport.send(Frame(kind: .control, payload: try JSONEncoder().encode(request)))

        guard let frame = try await transport.receive(), frame.kind == .control else {
            throw SyncSession.SyncError.closed
        }
        let accept = try JSONDecoder().decode(Accept.self, from: frame.payload)
        let key = Pairing.longTermKey(
            pairingSecret: pairingSecret, phoneNonce: nonce, macNonce: accept.nonce
        )
        return PairingStore.Peer(deviceId: accept.deviceId, name: accept.deviceName, key: key)
    }

    /// The Mac's half, mirror-image.
    public static func respond(
        over transport: SyncTransport,
        pairingSecret: Data,
        deviceId: String,
        deviceName: String
    ) async throws -> PairingStore.Peer {
        guard let frame = try await transport.receive(), frame.kind == .control else {
            throw SyncSession.SyncError.closed
        }
        let request = try JSONDecoder().decode(Request.self, from: frame.payload)
        let nonce = Pairing.makeSecret()
        let accept = Accept(deviceId: deviceId, deviceName: deviceName, nonce: nonce)
        try await transport.send(Frame(kind: .control, payload: try JSONEncoder().encode(accept)))

        let key = Pairing.longTermKey(
            pairingSecret: pairingSecret, phoneNonce: request.nonce, macNonce: nonce
        )
        return PairingStore.Peer(deviceId: request.deviceId, name: request.deviceName, key: key)
    }
}
