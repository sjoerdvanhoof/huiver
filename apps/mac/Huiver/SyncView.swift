import SwiftUI

/// Pairing and sync, from the Mac's chair.
///
/// The Mac is the passive side: it shows a code, then it answers. Everything
/// initiated — pairing, pressing sync — happens on the phone, so this screen
/// is mostly a status light with a QR button.
struct SyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacSyncModel.self) private var sync
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Palette.Space.lg) {
            Text("Connector")
                .font(.huiverTitle)
                .foregroundStyle(theme.colors.foreground)

            if sync.mode == .pairing, let qr = sync.qrImage {
                pairingCard(qr)
            } else if sync.pairedPhones.isEmpty {
                unpairedCard
            } else {
                pairedCard
            }

            if let failure = sync.failure {
                Text(failure)
                    .font(.huiverCaption)
                    .foregroundStyle(theme.colors.destructive)
            }

            Spacer()
        }
        .padding(Palette.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var unpairedCard: some View {
        VStack(alignment: .leading, spacing: Palette.Space.md) {
            Text("No phone paired yet.")
                .font(.huiverBody)
                .foregroundStyle(theme.colors.foreground)
            Text(
                "Pairing shows a code here; on the iPhone, open Settings → Connector → "
                    + "Pair with Mac and scan it. Both devices need to be on the same network."
            )
            .font(.huiverCaption)
            .foregroundStyle(theme.colors.mutedForeground)
            Button("Pair a phone") { sync.beginPairing(model: model) }
        }
        .padding(Palette.Space.lg)
        .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
    }

    private func pairingCard(_ qr: CGImage) -> some View {
        VStack(spacing: Palette.Space.md) {
            Image(decorative: qr, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 260, height: 260)
                .background(.white, in: .rect(cornerRadius: Palette.Radius.md))
            Text("Scan this with the iPhone. The code expires in two minutes.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
            Button("Cancel") { sync.cancelPairing(model: model) }
        }
        .frame(maxWidth: .infinity)
        .padding(Palette.Space.lg)
        .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
    }

    private var pairedCard: some View {
        VStack(alignment: .leading, spacing: Palette.Space.md) {
            ForEach(sync.pairedPhones) { phone in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.name)
                            .font(.huiverBody)
                            .foregroundStyle(theme.colors.foreground)
                        Text(status)
                            .font(.huiverCaption)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    Spacer()
                    Button("Unpair", role: .destructive) { sync.unpair(phone, model: model) }
                }
            }

            if let summary = sync.lastSummary, let at = sync.lastSyncedAt {
                Divider().overlay(theme.colors.border)
                Text(
                    "Last sync \(at.formatted(date: .omitted, time: .shortened)) — sent "
                        + "\(summary.sent), received \(summary.received), "
                        + "\(summary.progressMerged) positions merged."
                )
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
            }

            Text("Start a sync from the phone: Settings → Connector → Sync now.")
                .font(.huiverCaption)
                .foregroundStyle(theme.colors.mutedForeground)
        }
        .padding(Palette.Space.lg)
        .background(theme.colors.card, in: .rect(cornerRadius: Palette.Radius.lg))
    }

    private var status: String {
        switch sync.mode {
        case .syncing: return "Syncing now…"
        case .advertising: return "Listening on the local network"
        case .pairing: return "Pairing…"
        case .idle: return "Not listening"
        }
    }
}
