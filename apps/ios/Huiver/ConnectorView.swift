import SwiftUI
import VisionKit

/// The Connector: pair with the Mac, and sync.
///
/// Lives inside Settings as a section plus a scanner sheet, per the PRD.
/// Unpaired it is one button; paired it is the Mac's name, a sync button, and
/// what the last sync did.
struct ConnectorSection: View {
    @Environment(AppModel.self) private var model
    @Environment(SyncModel.self) private var sync
    @Environment(\.theme) private var theme

    @State private var showingScanner = false

    /// `SyncModel` is `@Observable` rather than a source of truth for a toggle,
    /// and the setting behind this one has a side effect — starting or stopping
    /// the watcher — so it is a computed binding rather than `@Bindable`.
    private var autoSyncBinding: Binding<Bool> {
        .init(get: { sync.autoSync }, set: { sync.autoSync = $0 })
    }

    var body: some View {
        Section {
            if let mac = sync.pairedMac {
                LabeledContent("Mac", value: mac.name)

                Button {
                    Task { await sync.syncNow(model: model) }
                } label: {
                    HStack {
                        Text(sync.activity == .syncing ? "Syncing…" : "Sync now")
                        Spacer()
                        if sync.activity == .syncing { ProgressView() }
                    }
                }
                .disabled(sync.activity == .syncing)

                if let summary = sync.lastSummary, let at = sync.lastSyncedAt {
                    LabeledContent(
                        "Last sync",
                        value: "\(at.formatted(date: .omitted, time: .shortened)) · "
                            + "↓\(summary.received) ↑\(summary.sent)"
                    )
                    if let skew = summary.clockSkew {
                        Text(
                            "The Mac's clock is \(Int(abs(skew) / 60)) minutes off, which can "
                                + "make resume positions pick the wrong side."
                        )
                        .font(.huiverCaption)
                        .foregroundStyle(theme.colors.destructive)
                    }
                }

                Toggle("Sync automatically", isOn: autoSyncBinding)

                Button("Unpair", role: .destructive) { sync.unpair() }
            } else {
                Button {
                    showingScanner = true
                } label: {
                    Label("Pair with Mac", systemImage: "qrcode.viewfinder")
                }
            }

            if case .failed(let message) = sync.activity {
                Text(message)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.destructive)
            }
        } header: {
            Text("Connector")
        } footer: {
            Text(
                sync.isPaired
                    ? "Sync moves books both ways, audio from the Mac, and listening positions "
                        + "whichever is newer. Directly between the two devices — nothing leaves "
                        + "your network. Automatic sync starts a session when the Mac appears on "
                        + "the network, at most once a minute."
                    : "Open Narcisse on your Mac, choose Pair a phone, and scan the code it shows."
            )
        }
        .sheet(isPresented: $showingScanner) {
            ScannerSheet { code in
                showingScanner = false
                Task { await sync.pair(with: code) }
            }
        }
    }
}

/// A QR scanner and nothing else.
///
/// `DataScannerViewController` needs a real device — the simulator has no
/// camera — so the sheet degrades to an explanation there rather than a black
/// square.
private struct ScannerSheet: View {
    let found: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported {
                    Scanner(found: found)
                } else {
                    Text("Scanning needs the camera, which this device does not have.")
                        .padding()
                }
            }
            .navigationTitle("Scan the code on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let found: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                isHighlightingEnabled: true
            )
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        func updateUIViewController(_: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(found: found) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let found: (String) -> Void
            init(found: @escaping (String) -> Void) { self.found = found }

            func dataScanner(
                _ scanner: DataScannerViewController,
                didAdd added: [RecognizedItem],
                allItems _: [RecognizedItem]
            ) {
                for item in added {
                    if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                        scanner.stopScanning()
                        found(value)
                        return
                    }
                }
            }
        }
    }
}
