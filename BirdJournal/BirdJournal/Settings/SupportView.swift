import SwiftUI

/// Settings → Support Bird Journal (issue #59, ADR-0001): what a tip pays for, the three tips with the App Store's
/// prices, and a thank-you once one goes through. Every feature stays free, so a tip unlocks nothing.
struct SupportView: View {
    /// The promise the screen makes; `NoPurchaseGateTests` holds the copy to it.
    static let unlocksNothing = "Tips are one-time and unlock nothing. Every feature of Bird Journal stays free for everyone, whether you tip or not."
    static let pitch = "Bird Journal is free and has no ads. If you'd like to help, a tip goes toward the server that keeps the bird packs and circles running, and the machine at home that paints the cards."
    static let privacy = "No account needed. Apple handles the payment; Bird Journal keeps no record of it and sends nothing to its server."

    @State private var tipJar = TipJar()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Support Bird Journal", systemImage: "heart")
                        .font(JournalFont.heading)
                        .foregroundStyle(Color.ink)
                    Text(Self.pitch)
                        .font(JournalFont.body)
                        .foregroundStyle(Color.ink)
                    Text(Self.unlocksNothing)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            }

            if case .thanked(let tipName) = tipJar.state {
                Section {
                    ThankYouNote(tipName: tipName) { tipJar.reset() }
                }
            } else {
                Section {
                    tips
                } header: {
                    Text("Leave a tip")
                } footer: {
                    Text(Self.privacy)
                }
            }
        }
        .paperList()
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await tipJar.load()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "autoTipThanks") { tipJar.showThanksForScreenshot() }
            #endif
        }
    }

    @ViewBuilder private var tips: some View {
        switch tipJar.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Asking the App Store…").foregroundStyle(Color.inkSecondary)
            }
        case .unavailable(let message):
            ErrorNotice("No tips right now", message: message, symbol: "wifi.slash") {
                Button("Try again") { Task { await tipJar.load() } }
            }
            .listRowInsets(EdgeInsets())
        case .ready, .purchasing, .pending, .failed, .thanked:
            ForEach(tipJar.products, id: \.id) { product in
                TipRow(name: product.displayName, detail: product.description, price: product.displayPrice, isPurchasing: tipJar.state == .purchasing(productID: product.id)) {
                    Task { await tipJar.purchase(product) }
                }
                .disabled(tipJar.state.isBusy)
            }
            if tipJar.state == .pending {
                Text("Your tip is waiting for approval. It goes through on its own once it's approved.")
                    .font(JournalFont.supporting)
                    .foregroundStyle(Color.inkSecondary)
            }
            if case .failed(let message) = tipJar.state {
                Text(message)
                    .font(JournalFont.supporting)
                    .foregroundStyle(.red)
            }
        }
    }
}

private extension TipJar.State {
    var isBusy: Bool {
        if case .purchasing = self { return true }
        return false
    }
}

/// One tip: its name and line from App Store Connect, and the price as the button.
private struct TipRow: View {
    let name: String
    let detail: String
    let price: String
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(JournalFont.rowTitle)
                    .foregroundStyle(Color.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(JournalFont.supporting)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: action) {
                if isPurchasing {
                    ProgressView()
                } else {
                    Text(price)
                }
            }
            .buttonStyle(.journalOutlined)
            .accessibilityLabel("Tip \(price), \(name)")
        }
        .padding(.vertical, 4)
    }
}

/// After a tip: thanks, and a reminder that nothing changed because nothing needed to.
private struct ThankYouNote: View {
    let tipName: String
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Thank you!", systemImage: "checkmark.circle.fill")
                .font(JournalFont.heading)
                .foregroundStyle(Color.moss)
            Text("Thanks for the \(tipName.lowercased()). It helps keep the server up and the painting machine painting. Nothing in the app changes: it was all yours already.")
                .font(JournalFont.body)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back to the tips", action: again)
                .buttonStyle(.journalOutlined)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tip-thanks")
    }
}
