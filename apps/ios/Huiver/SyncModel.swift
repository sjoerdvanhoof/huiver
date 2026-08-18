import Foundation
import Observation

/// The phone's side of pairing and syncing, as the Connector screen sees it.
///
/// Owns nothing durable itself: the pairing lives in the Keychain, the data in
/// the library and the progress store. This is the state machine between them
/// and the buttons.
@MainActor
@Observable
final class SyncModel {
    enum Activity: Equatable {
        case idle
        case pairing
        case syncing
        case failed(String)
    }

    private(set) var activity: Activity = .idle
    private(set) var pairedMac: PairingStore.Peer?
    private(set) var lastSummary: SyncSession.Summary?
    /// Set once per launch, so the Connector row can show when things last
    /// moved without a persistent store of its own.
    private(set) var lastSyncedAt: Date?

    private let store = PairingStore()
    private let deviceId = DeviceIdentity.id()

    init() {
        // One Mac in v1. The store holds many peers; the UI holds one.
        pairedMac = store.peers().first
    }

    var isPaired: Bool { pairedMac != nil }

    /// Scan result → stored pairing.
    func pair(with code: String) async {
        guard let payload = Pairing.QRPayload.decode(code), let secret = payload.secret else {
            activity = .failed("That is not a huiver pairing code.")
            return
        }
        guard !payload.isExpired else {
            activity = .failed("That code has expired — show a fresh one on the Mac.")
            return
        }
        activity = .pairing
        do {
            let endpoint = try await SyncClient.find(serviceName: payload.id)
            // The identity is how the listener picks a key, so both sides must
            // present the same string. During pairing there is exactly one key
            // in play, so it is a constant; after pairing it is the phone's
            // device id, which is what lets one Mac hold keys for two phones.
            let transport = try await SyncClient.connect(
                to: endpoint, psk: secret, pskIdentity: Pairing.pairingIdentity
            )
            let peer = try await PairingExchange.initiate(
                over: transport,
                pairingSecret: secret,
                deviceId: deviceId,
                deviceName: deviceName()
            )
            await transport.close()
            store.save(peer)
            pairedMac = peer
            activity = .idle
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    /// The button. Books both ways, audio Mac→phone, progress newest-wins.
    func syncNow(model: AppModel) async {
        guard let mac = pairedMac, let library = model.library,
              let progress = model.progressStore
        else { return }
        activity = .syncing
        do {
            PlaybackLog.note(
                "sync: connecting as \(deviceId.prefix(13))… to \(mac.deviceId.prefix(13))… "
                    + "(key \(mac.key.count)B, \(mac.key.prefix(4).map { String(format: "%02x", $0) }.joined()))"
            )
            let endpoint = try await SyncClient.find(serviceName: mac.deviceId)
            let transport = try await SyncClient.connect(
                to: endpoint, psk: mac.key, pskIdentity: deviceId
            )
            let source = LibrarySyncDataSource(
                library: library,
                progress: progress,
                deviceId: deviceId,
                voiceDirectory: URL.documentsDirectory.appendingPathComponent("voices")
            )
            let session = SyncSession(
                transport: transport,
                role: .client,
                source: source,
                identity: SyncMessage.Hello(
                    deviceId: deviceId,
                    deviceName: deviceName(),
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String ?? "0"
                ),
                wantsAudio: true
            )
            lastSummary = try await session.run()
            await transport.close()
            lastSyncedAt = Date()
            activity = .idle
            await model.refresh()
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    func unpair() {
        if let mac = pairedMac { store.remove(mac.deviceId) }
        pairedMac = nil
        lastSummary = nil
    }

    func clearFailure() {
        if case .failed = activity { activity = .idle }
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "huiver"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
