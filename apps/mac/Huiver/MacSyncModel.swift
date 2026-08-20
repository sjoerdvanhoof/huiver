import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Observation
import SwiftUI

/// The Mac's side of pairing and syncing.
///
/// One listener at a time. Normally it listens for the paired phone with the
/// long-term key; while the QR code is on screen it listens with the ephemeral
/// pairing secret instead, and flips back the moment a phone pairs. The
/// service name is this Mac's device id — stable, unique, and what the QR
/// tells the phone to browse for.
@MainActor
@Observable
final class MacSyncModel {
    enum Mode: Equatable {
        case idle
        case advertising
        case pairing
        case syncing
    }

    private(set) var mode: Mode = .idle
    private(set) var pairedPhones: [PairingStore.Peer] = []
    private(set) var qrImage: CGImage?
    private(set) var lastSummary: SyncSession.Summary?
    private(set) var lastSyncedAt: Date?
    private(set) var failure: String?

    private let store = PairingStore()
    private let deviceId = DeviceIdentity.id()
    private let server = SyncServer()
    private var pairingSecret: Data?

    init() {
        pairedPhones = store.peers()
    }

    /// Start answering the paired phone. Called once the library is loaded.
    func startAdvertising(model: AppModel) {
        // v1 pairs one phone; the store can hold more for later.
        guard let phone = pairedPhones.first else { return }
        do {
            try server.start(
                serviceName: deviceId,
                psk: phone.key,
                pskIdentity: phone.deviceId,
                onConnection: { [weak self, weak model] transport in
                    guard let self, let model else { return }
                    await self.serve(transport, model: model)
                }
            )
            mode = .advertising
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Put a fresh code on screen and listen with its secret.
    func beginPairing(model: AppModel) {
        let secret = Pairing.makeSecret()
        pairingSecret = secret
        let payload = Pairing.QRPayload(id: deviceId, name: hostName(), psk: secret)
        guard let encoded = try? payload.encoded() else { return }
        qrImage = Self.qrCode(for: encoded)

        do {
            server.stop()
            try server.start(
                serviceName: deviceId,
                psk: secret,
                pskIdentity: Pairing.pairingIdentity,
                onConnection: { [weak self, weak model] transport in
                    guard let self, let model else { return }
                    await self.acceptPairing(transport, model: model)
                }
            )
            mode = .pairing
        } catch {
            failure = error.localizedDescription
        }
    }

    func cancelPairing(model: AppModel) {
        qrImage = nil
        pairingSecret = nil
        server.stop()
        mode = .idle
        startAdvertising(model: model)
    }

    func unpair(_ peer: PairingStore.Peer, model: AppModel) {
        store.remove(peer.deviceId)
        pairedPhones = store.peers()
        server.stop()
        mode = .idle
        startAdvertising(model: model)
    }

    private func acceptPairing(_ transport: NWSyncTransport, model: AppModel) async {
        guard let secret = pairingSecret else { return }
        do {
            let peer = try await PairingExchange.respond(
                over: transport,
                pairingSecret: secret,
                deviceId: deviceId,
                deviceName: hostName()
            )
            await transport.close()
            guard store.save(peer) else {
                failure = "The pairing completed but could not be stored in the Keychain."
                return
            }
            pairedPhones = store.peers()
            qrImage = nil
            // The secret is spent: one QR, one phone.
            pairingSecret = nil
            server.stop()
            startAdvertising(model: model)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func serve(_ transport: NWSyncTransport, model: AppModel) async {
        guard let library = model.library, let progress = model.progressStore else { return }
        mode = .syncing
        defer { mode = .advertising }
        do {
            let source = LibrarySyncDataSource(
                library: library,
                progress: progress,
                deviceId: deviceId,
                voiceDirectory: Bundle.main.resourceURL?.appendingPathComponent("Voices"),
                // The Mac asks for nothing and renders for the phone, so it has
                // the accepting half of offload and not the asking one.
                acceptRequests: { [weak model] requests in
                    guard let model else { return [] }
                    return await model.acceptConvertRequests(requests)
                }
            )
            let session = SyncSession(
                transport: transport,
                role: .server,
                source: source,
                identity: SyncMessage.Hello(
                    deviceId: deviceId,
                    deviceName: hostName(),
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String ?? "0"
                ),
                // The Mac renders faster than the phone ever will; audio flows
                // one way.
                wantsAudio: false
            )
            lastSummary = try await session.run()
            lastSyncedAt = Date()
            await transport.close()
            await model.refresh()
            // Now the books that arrived in this session are in the library,
            // the asks that were waiting for them can be queued. The phone
            // hears the real state of those next time it connects.
            model.placeDeferredRequests()
        } catch {
            // A dropped connection mid-sync is ordinary — the phone left the
            // room. The next session's diff picks up the remainder.
            PlaybackLog.note("sync: session ended early: \(error.localizedDescription)")
        }
    }

    private func hostName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    private static func qrCode(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Rendered at 10x so SwiftUI scales a crisp image down rather than a
        // 30-pixel one up into mush.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
