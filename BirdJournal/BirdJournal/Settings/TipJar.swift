import Foundation
import Observation
import StoreKit

/// The tip jar (issue #59, ADR-0001): three StoreKit 2 consumables that unlock nothing. A tip is finished as soon as
/// it is verified and is never looked up again, so no feature can check for one; nothing is sent to a server and no
/// account is needed. This is the only file in the app that imports StoreKit (`NoPurchaseGateTests` holds it there).
@MainActor
@Observable
final class TipJar {
    /// The product IDs, cheapest first, as configured in App Store Connect and in `BirdJournal.storekit`.
    static let productIDs = [
        "com.matthewcelia.mybirdjournal.tip.seed",
        "com.matthewcelia.mybirdjournal.tip.suet",
        "com.matthewcelia.mybirdjournal.tip.feeder",
    ]

    enum State: Equatable {
        case loading
        case ready
        /// The App Store could not be reached, or it returned no tips.
        case unavailable(String)
        case purchasing(productID: String)
        /// Waiting on Ask to Buy or a payment check; the tip is finished when it arrives.
        case pending
        /// A tip went through and was finished.
        case thanked(tipName: String)
        case failed(String)
    }

    private(set) var products: [Product] = []
    private(set) var state = State.loading
    private var updates: Task<Void, Never>?

    init() {
        // Ask to Buy approvals and interrupted purchases arrive here, including ones left from an earlier launch.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.finish(result)
            }
        }
    }

    isolated deinit {
        updates?.cancel()
    }

    func load() async {
        if case .thanked = state { return }
        state = .loading
        do {
            let found = try await Product.products(for: Self.productIDs)
            products = found.sorted { $0.price < $1.price }
            state = products.isEmpty ? .unavailable("The tips aren't available right now. Try again later.") : .ready
        } catch {
            state = .unavailable("The App Store couldn't be reached. Try again when you're online.")
        }
    }

    func purchase(_ product: Product) async {
        state = .purchasing(productID: product.id)
        do {
            switch try await product.purchase() {
            case .success(let result):
                await finish(result)
            case .pending:
                state = .pending
            case .userCancelled:
                state = .ready
            @unknown default:
                state = .ready
            }
        } catch {
            state = .failed("The tip didn't go through: \(error.localizedDescription)")
        }
    }

    /// Back to the tips after a thank-you or a failure.
    func reset() {
        state = products.isEmpty ? .loading : .ready
    }

    #if DEBUG
    /// The thank-you as after the cheapest tip (`-autoTipThanks YES`), for screenshots.
    func showThanksForScreenshot() {
        state = .thanked(tipName: products.first?.displayName ?? "Scoop of seed")
    }
    #endif

    private func finish(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            guard Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil else { return }
            let name = products.first { $0.id == transaction.productID }?.displayName ?? "tip"
            state = .thanked(tipName: name)
        case .unverified(let transaction, _):
            // Finished all the same so StoreKit stops offering it; there is nothing to grant either way.
            await transaction.finish()
            state = .failed("The App Store couldn't confirm the tip.")
        }
    }
}
