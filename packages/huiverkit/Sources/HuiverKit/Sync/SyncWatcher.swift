import Foundation
import Network

/// Watches Bonjour for one Mac and says when it turns up.
///
/// The counterpart to `SyncClient.find`, which browses until it sees the
/// service once and then stops. This keeps browsing, and reports the *edge* —
/// the moment a Mac that was not there is — because that is the moment worth
/// syncing on. Level-triggered would mean starting a session every time the
/// browser reported its results, which it does whenever anything on the network
/// changes.
///
/// Nothing here decides whether to sync; that is policy, and it lives with the
/// sync model along with the throttle and the setting that turns it off.
public final class SyncWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "huiver.sync.watch")
    private var browser: NWBrowser?
    /// Whether the Mac was visible at the last report. The edge is what is
    /// interesting, so this is the whole state machine.
    private var wasPresent = false

    public init() {}

    public var isRunning: Bool { browser != nil }

    /// Start watching for a service by name, calling back each time it appears.
    ///
    /// Idempotent: starting a watcher that is already running does nothing, so
    /// this can be called from every foreground transition without keeping
    /// track.
    public func start(serviceName: String, onAppear: @escaping @Sendable () -> Void) {
        guard browser == nil else { return }
        let parameters = NWParameters()
        // The same peer-to-peer flag the rest of sync uses, so a Mac and a
        // phone with no router between them still find each other.
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: SyncProtocol.serviceType, domain: nil), using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let present = results.contains { result in
                if case .service(let name, _, _, _) = result.endpoint { return name == serviceName }
                return false
            }
            defer { self.wasPresent = present }
            guard present, !self.wasPresent else { return }
            onAppear()
        }
        browser.stateUpdateHandler = { [weak self] state in
            // A browser that fell over stops reporting, and would leave the
            // phone thinking it is watching when it is not.
            if case .failed(let error) = state {
                PlaybackLog.note("sync: watcher failed: \(error.localizedDescription)")
                self?.stop()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        wasPresent = false
    }

    deinit { browser?.cancel() }
}
