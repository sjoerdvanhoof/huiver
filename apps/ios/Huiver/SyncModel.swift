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
    /// When things last moved. Persisted, so "when did this last work?" has
    /// an answer after a relaunch rather than only within one.
    private(set) var lastSyncedAt: Date? {
        didSet { UserDefaults.standard.set(lastSyncedAt, forKey: "lastSyncedAt") }
    }

    private let store = PairingStore()
    private let deviceId = DeviceIdentity.id()
    private let watcher = SyncWatcher()
    /// The model the watcher syncs against, so a session started by the Mac
    /// appearing has something to read and write. Weak: the watcher outlives
    /// nothing, but it must not be what keeps the library alive.
    private weak var watching: AppModel?
    /// When the last unattended sync started, so a Mac that flickers on and off
    /// the network does not mean a session every few seconds.
    private var lastAutoSyncAt: Date?

    /// Identifier registered in Info.plist under
    /// `BGTaskSchedulerPermittedIdentifiers`. Must match exactly or the
    /// registration throws at launch.
    static let backgroundTaskIdentifier = "com.hoofkantoor.huiver.sync"

    /// The live model, for the background handler to find — the same trick the
    /// converter uses, and for the same reason: registration has to happen
    /// before the app finishes launching, which is before there is a model.
    private static weak var current: SyncModel?

    /// How long after an unattended sync before another one is worth starting.
    static let autoSyncInterval: TimeInterval = 60

    init() {
        // One Mac in v1. The store holds many peers; the UI holds one.
        pairedMac = store.peers().first
        lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Date
        SyncModel.current = self
    }

    var isPaired: Bool { pairedMac != nil }

    /// Sync without being asked, when the Mac turns up.
    ///
    /// On by default: two devices in the same room with a long-term key between
    /// them and a diff to compute is the whole point, and a button that has to
    /// be pressed is a book that is not on the phone.
    var autoSync: Bool {
        get { UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoSync")
            if newValue {
                if let watching { startWatching(model: watching) }
            } else {
                watcher.stop()
            }
        }
    }

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
            // The Keychain can refuse — see `PairingStore.save`'s own note
            // that a refusal must surface. Setting `pairedMac` anyway showed
            // a pairing that silently evaporated at the next relaunch.
            guard store.save(peer) else {
                activity = .failed(
                    "The pairing could not be saved to the Keychain, so it would "
                        + "not survive a relaunch. Try pairing again."
                )
                return
            }
            pairedMac = peer
            activity = .idle
        } catch {
            activity = .failed(error.localizedDescription)
        }
    }

    // MARK: - Syncing without being asked

    /// Watch for the Mac and sync when it appears.
    ///
    /// Called on every foreground transition; the watcher itself is idempotent,
    /// so this needs no bookkeeping of its own.
    func startWatching(model: AppModel) {
        watching = model
        guard autoSync, let mac = pairedMac else { return }
        watcher.start(serviceName: mac.deviceId) { [weak self] in
            Task { @MainActor in await self?.autoSyncIfDue() }
        }
    }

    func stopWatching() {
        watcher.stop()
    }

    /// One unattended session, if enough has happened since the last one.
    ///
    /// The throttle is here rather than in the watcher because this is where
    /// the reasons to decline live: already syncing, just synced, switched off.
    private func autoSyncIfDue() async {
        // `library` is nil until the app has finished opening it, which can be
        // after the Mac has already been seen. Declining without starting the
        // throttle means the next sighting still counts.
        guard autoSync, let model = watching, model.library != nil, activity != .syncing else {
            return
        }
        if let last = lastAutoSyncAt,
           Date().timeIntervalSince(last) < Self.autoSyncInterval { return }
        lastAutoSyncAt = Date()
        await syncNow(model: model)
    }

    /// The button, and also what the watcher calls. Books both ways, audio
    /// Mac→phone, progress newest-wins.
    func syncNow(model: AppModel) async {
        guard let mac = pairedMac, let library = model.library,
              let progress = model.progressStore
        else { return }
        activity = .syncing
        // A transfer that is in flight when the phone goes in a pocket gets a
        // few seconds to finish rather than being cut off mid-chapter. It is
        // not background sync — iOS has no background mode that would run this
        // — but it is the difference between a chapter arriving and the next
        // session having to ask for it again.
        beginBackgroundAssertion()
        defer { endBackgroundAssertion() }
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
                voiceDirectory: URL.documentsDirectory.appendingPathComponent("voices"),
                // The asks travel in the manifest, and the Mac's answers come
                // back into the same store.
                requests: model.convertRequests
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
        watcher.stop()
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

    // MARK: - Leaving the app mid-sync

    #if canImport(UIKit)
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func beginBackgroundAssertion() {
        #if canImport(UIKit)
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "huiver-sync") {
            // Time is up. The session is not cancelled — it is holding a socket
            // that is about to be torn down anyway — but the assertion has to
            // be handed back or iOS kills the app for keeping it.
            Task { @MainActor [weak self] in self?.endBackgroundAssertion() }
        }
        #endif
    }

    private func endBackgroundAssertion() {
        #if canImport(UIKit)
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
        #endif
    }

    // MARK: - Syncing on the system's schedule

    /// Ask for a slot to sync in later.
    ///
    /// The same bargain the converter makes: iOS grants `BGProcessingTask` when
    /// it feels like it — typically charging and idle — so this is what
    /// finishes a large first sync overnight rather than something that runs
    /// the moment the screen locks. Requires the network, and asks for it.
    func scheduleBackgroundSync() {
        #if canImport(UIKit)
        guard isPaired, autoSync else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(UIKit)
    /// Register the handler. Must be called before the app finishes launching,
    /// and the identifier must appear in `BGTaskSchedulerPermittedIdentifiers`
    /// or this throws.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier, using: nil
        ) { task in
            handleBackgroundTask(task)
        }
    }

    /// BGTaskScheduler invokes its callback on a private dispatch queue. Keep
    /// that callback nonisolated, then explicitly enter the main actor before
    /// touching the observable sync model. A closure lexically created inside
    /// this @MainActor type inherits its isolation and traps at runtime before
    /// its first statement when Apple calls it off-main.
    private nonisolated static func handleBackgroundTask(_ task: BGTask) {
        let scheduled = SendableBackgroundTask(task)
        scheduled.value.expirationHandler = {
            // Nothing to unwind: an interrupted session leaves a smaller diff
            // for the next one, which is the whole design.
            scheduled.value.setTaskCompleted(success: false)
        }
        Task { @MainActor in
            // `watching` is set when the app comes to the foreground, so this
            // finds a model when the app is suspended rather than terminated.
            guard let sync = SyncModel.current, let model = sync.watching,
                  sync.isPaired, sync.autoSync
            else {
                scheduled.value.setTaskCompleted(success: false)
                return
            }
            await sync.syncNow(model: model)
            sync.scheduleBackgroundSync()
            scheduled.value.setTaskCompleted(success: true)
        }
    }
    #endif
}

#if canImport(UIKit)
import BackgroundTasks
import UIKit

/// BGTask has no Sendable annotation, although Apple explicitly hands the same
/// task from its scheduler queue to the asynchronous handler and completion
/// calls. This wrapper documents that single framework-owned crossing.
private final class SendableBackgroundTask: @unchecked Sendable {
    let value: BGTask
    init(_ value: BGTask) { self.value = value }
}
#endif
