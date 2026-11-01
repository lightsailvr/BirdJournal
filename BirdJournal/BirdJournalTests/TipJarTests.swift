import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import BirdJournal

// Issue #59: the tip jar against `BirdJournal.storekit`. A tip goes through, is finished, thanks the birder and
// leaves nothing behind for a feature to check.
@MainActor
@Suite("Tip jar", .serialized)
struct TipJarTests {
    let session: SKTestSession

    init() throws {
        let url = try #require(Bundle.allBundles.lazy.compactMap { $0.url(forResource: "BirdJournal", withExtension: "storekit") }.first)
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    @Test("Three consumable tips load, cheapest first")
    func loadsThreeTips() async throws {
        let jar = TipJar()
        await jar.load()
        #expect(jar.state == .ready)
        #expect(jar.products.map(\.id) == TipJar.productIDs)
        #expect(jar.products.allSatisfy { $0.type == .consumable })
    }

    @Test("A tip finishes its transaction, shows the thank-you and unlocks nothing")
    func purchaseFinishesAndThanks() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.products.first)

        await jar.purchase(tip)

        #expect(jar.state == .thanked(tipName: tip.displayName))
        let transactions = session.allTransactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.productIdentifier == tip.id)
        #expect(transactions.first?.pendingAskToBuyConfirmation == false)
        // Finished: StoreKit has nothing left to hand out, and a consumable is never an entitlement.
        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        #expect(unfinished == 0)
        var entitlements = 0
        for await _ in Transaction.currentEntitlements { entitlements += 1 }
        #expect(entitlements == 0)
    }

    @Test("The same tip can be left again")
    func tipsAreRepeatable() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.products.last)
        await jar.purchase(tip)
        jar.reset()
        #expect(jar.state == .ready)
        await jar.purchase(tip)
        #expect(jar.state == .thanked(tipName: tip.displayName))
        #expect(session.allTransactions().count == 2)
    }

    @Test("A failed purchase says so and thanks no one")
    func failedPurchase() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.products.first)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)

        await jar.purchase(tip)

        guard case .failed = jar.state else {
            Issue.record("expected a failure, got \(jar.state)")
            return
        }
        #expect(session.allTransactions().isEmpty)
    }

    @Test("Ask to Buy waits, then thanks once approved")
    func askToBuy() async throws {
        session.askToBuyEnabled = true
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.products.first)

        await jar.purchase(tip)
        #expect(jar.state == .pending)

        let pending = try #require(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        for _ in 0..<50 where jar.state == .pending {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(jar.state == .thanked(tipName: tip.displayName))
    }
}
