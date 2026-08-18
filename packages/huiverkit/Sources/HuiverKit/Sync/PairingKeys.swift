import CryptoKit
import Foundation
import Network
import Security

/// Pairing: how two devices come to share a secret, and where it lives after.
///
/// The Mac shows a QR code holding a fresh random secret; the phone scans it
/// and connects with TLS-PSK using that secret. There is no certificate and no
/// third party — completing the TLS handshake *is* the proof that the phone
/// read this Mac's screen, which for two devices on a desk is exactly the trust
/// that exists. Both sides then derive a long-term key over the encrypted
/// channel and keep it in the Keychain; the QR secret dies with the pairing
/// session.
public enum Pairing {
    /// What the QR code says. Small on purpose — a QR with a URL's worth of
    /// JSON scans from across a desk; one with a kilobyte does not.
    public struct QRPayload: Codable, Sendable, Equatable {
        public var v: Int
        /// The Mac's stable device id, so the phone browses for *this* Mac
        /// rather than whichever huiver answers first.
        public var id: String
        public var name: String
        /// The ephemeral pairing secret, base64.
        public var psk: String
        /// Unix seconds after which the Mac refuses this secret. Two minutes:
        /// long enough to find the camera, short enough that a photographed
        /// screen goes stale.
        public var exp: Double

        public init(id: String, name: String, psk: Data, lifetime: TimeInterval = 120) {
            self.v = 1
            self.id = id
            self.name = name
            self.psk = psk.base64EncodedString()
            self.exp = Date().addingTimeInterval(lifetime).timeIntervalSince1970
        }

        public var secret: Data? { Data(base64Encoded: psk) }
        public var isExpired: Bool { Date().timeIntervalSince1970 > exp }

        public func encoded() throws -> String {
            String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        }

        public static func decode(_ string: String) -> QRPayload? {
            guard let payload = try? JSONDecoder().decode(QRPayload.self, from: Data(string.utf8)),
                  payload.v == 1
            else { return nil }
            return payload
        }
    }

    /// The PSK identity used during pairing, identical on both sides.
    ///
    /// TLS-PSK servers select the key by the identity the client presents, so
    /// a mismatch is a handshake that fails forever while the connection sits
    /// in `.waiting` looking exactly like a permissions problem. One key is in
    /// play during pairing, so one constant string names it.
    public static let pairingIdentity = "huiver-pair-v1"

    public static func makeSecret() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// The key both sides keep, derived from the QR secret and both nonces.
    ///
    /// Derived rather than reused so that the thing that was briefly on screen
    /// — photographable, in a QR code — is not the thing that protects every
    /// future sync. An attacker with a photo of the QR has two minutes and
    /// needs to have completed a handshake within them.
    public static func longTermKey(
        pairingSecret: Data, phoneNonce: Data, macNonce: Data
    ) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingSecret),
            salt: phoneNonce + macNonce,
            info: Data("huiver-pair-v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Where paired-device keys live: the Keychain, one entry per peer.
///
/// Not UserDefaults — this key authenticates every future connection, and it
/// should survive as a secret survives, not as a preference does.
public struct PairingStore: Sendable {
    public struct Peer: Codable, Sendable, Equatable, Identifiable {
        public var deviceId: String
        public var name: String
        public var key: Data
        public var pairedAt: Date

        public var id: String { deviceId }

        public init(deviceId: String, name: String, key: Data, pairedAt: Date = Date()) {
            self.deviceId = deviceId
            self.name = name
            self.key = key
            self.pairedAt = pairedAt
        }
    }

    static let service = "online.mo4.huiver.sync"

    public init() {}

    #if os(macOS)
    /// On the Mac the pairing lives in a file, not the Keychain.
    ///
    /// Four separate failures earned this: the data-protection keychain wants
    /// an entitlement a local build lacks, and the login keychain binds items
    /// to the app's code signature — which changes subtly with every rebuild
    /// of a development app, so reads and overwrites degrade in ways that are
    /// invisible from inside a sandboxed GUI process. A file in the app's own
    /// container has none of those moods. The key it holds protects a book
    /// library on a personal machine; the sandbox already guards the file as
    /// well as it guards the library itself.
    private static var fileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Huiver")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("pairing.json")
    }

    private struct FileStore: Codable {
        var deviceId: String?
        var peers: [Peer] = []
    }

    private static func readFile() -> FileStore {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(FileStore.self, from: data)
        else { return FileStore() }
        return store
    }

    private static func writeFile(_ store: FileStore) -> Bool {
        guard let data = try? JSONEncoder().encode(store) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            PlaybackLog.note("pairing: file save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func fileDeviceId() -> String {
        var store = readFile()
        if let existing = store.deviceId { return existing }
        let fresh = UUID().uuidString
        store.deviceId = fresh
        _ = writeFile(store)
        return fresh
    }
    #endif

    /// The keychain differs per platform, and pretending otherwise cost two
    /// rounds of silent failure.
    ///
    /// On iOS there is one keychain — the data-protection one — and
    /// `kSecAttrAccessible` belongs on every item. On macOS that keychain
    /// exists too, but only for apps carrying an application-identifier
    /// entitlement from a provisioning profile, which a locally built
    /// development app does not have: `SecItemAdd` fails with
    /// errSecMissingEntitlement. So the Mac uses the classic login keychain,
    /// which any signed app may use, and skips the accessibility attribute
    /// that keychain does not accept.
    private static func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if !os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Mark an add-query with the right accessibility for its platform.
    static func markAccessible(_ query: inout [String: Any]) {
        #if !os(macOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
    }

    /// Whether the entry actually landed — a refusal must surface, not vanish.
    @discardableResult
    public func save(_ peer: Peer) -> Bool {
        #if os(macOS)
        var store = Self.readFile()
        store.peers.removeAll { $0.deviceId == peer.deviceId }
        store.peers.append(peer)
        return Self.writeFile(store)
        #else
        return keychainSave(peer)
        #endif
    }

    private func keychainSave(_ peer: Peer) -> Bool {
        guard let data = try? JSONEncoder().encode(peer) else { return false }
        let query = Self.baseQuery(account: peer.deviceId)
        // Delete-then-add rather than update: simpler, and pairing is rare.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // On iOS: reachable once the device has been unlocked, never leaves
        // the device via backup. On macOS the login keychain has its own
        // rules and refuses the attribute.
        Self.markAccessible(&add)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            PlaybackLog.note("pairing: keychain save failed (\(status))")
        }
        return status == errSecSuccess
    }

    public func peers() -> [Peer] {
        #if os(macOS)
        return Self.readFile().peers
        #else
        return keychainPeers()
        #endif
    }

    private func keychainPeers() -> [Peer] {
        var query = Self.baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [Data] else {
            // errSecItemNotFound is the ordinary empty store; anything else is
            // the keychain refusing us, which has already happened three ways
            // on macOS and must never again be indistinguishable from
            // "nothing paired".
            if status != errSecItemNotFound {
                PlaybackLog.note("pairing: keychain read failed (\(status))")
            }
            return []
        }
        let peers = items.compactMap { try? JSONDecoder().decode(Peer.self, from: $0) }
        PlaybackLog.note("pairing: \(peers.count) peer(s) in the keychain")
        return peers
    }

    public func peer(_ deviceId: String) -> Peer? {
        peers().first { $0.deviceId == deviceId }
    }

    public func remove(_ deviceId: String) {
        #if os(macOS)
        var store = Self.readFile()
        store.peers.removeAll { $0.deviceId == deviceId }
        _ = Self.writeFile(store)
        #else
        SecItemDelete(Self.baseQuery(account: deviceId) as CFDictionary)
        #endif
    }
}

/// This device's own identity: a UUID minted once and kept in the Keychain, so
/// it survives reinstalling the app rather than becoming a "new" device that
/// every peer has to pair with again.
public enum DeviceIdentity {
    static let account = "device-id"

    public static func id() -> String {
        #if os(macOS)
        return PairingStore.fileDeviceId()
        #else
        return keychainId()
        #endif
    }

    private static func keychainId() -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PairingStore.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        #if !os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let existing = String(data: data, encoding: .utf8) {
            return existing
        }
        let fresh = UUID().uuidString
        query[kSecReturnData as String] = nil
        query[kSecValueData as String] = Data(fresh.utf8)
        PairingStore.markAccessible(&query)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            PlaybackLog.note("pairing: device id save failed (\(status))")
        }
        return fresh
    }
}

/// TLS parameters for a pre-shared key.
///
/// TLS 1.2 pinned deliberately: Network.framework's TLS 1.3 does not expose
/// external-PSK ciphersuites, and 1.2 with AES-GCM and a 32-byte key is not the
/// weak link in a system whose alternative was plaintext. A wrong key cannot
/// complete the handshake, which is the mutual authentication.
public enum SyncTLS {
    public static func parameters(psk: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions

        psk.withUnsafeBytes { raw in
            let key = DispatchData(bytes: raw)
            identity.data(using: .utf8)!.withUnsafeBytes { idRaw in
                let id = DispatchData(bytes: idRaw)
                sec_protocol_options_add_pre_shared_key(
                    options, key as __DispatchData, id as __DispatchData
                )
            }
        }
        // 0x00A8 = TLS_PSK_WITH_AES_128_GCM_SHA256, which SDK enums don't name.
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = true
        return parameters
    }
}
