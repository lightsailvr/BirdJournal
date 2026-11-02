import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import BirdJournal

// Issue #59: the tip jar against `BirdJournal.storekit`. A tip goes through, is finished, thanks the birder and
// leaves nothing behind for a feature to check.
//
// Issue #93: nothing here waits on the wall clock. A purchase that reaches the sandbox instead of the session waits
// on an Apple Account sign-in for ever; that is what timed out on new simulators (a simulator's StoreKit uses the
// session's configuration only in processes launched after the first session registered it), and
// `scripts/build-and-test.sh` primes a new simulator so it cannot happen there. The time limit turns any other such
// wait into a failure in a minute instead of xcodebuild's three.
@MainActor
@Suite("Tip jar", .serialized, .timeLimit(.minutes(1)))
struct TipJarTests {
    /// One session for the whole suite: a session torn down per test leaves later purchases going to the sandbox,
    /// which asks for an Apple Account.
    static let shared: SKTestSession? = Bundle.allBundles.lazy
        .compactMap { $0.url(forResource: "BirdJournal", withExtension: "storekit") }.first
        .flatMap { try? SKTestSession(contentsOf: $0) }

    let session: SKTestSession

    init() throws {
        session = try #require(Self.shared, "BirdJournal.storekit is missing from the test bundle")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    @Test("Three consumable tips load, cheapest first")
    func loadsThreeTips() async throws {
        let jar = TipJar()
        await jar.load()
        #expect(jar.state == .ready)
        #expect(jar.tips.map(\.id) == TipJar.productIDs)
        let products = try await Product.products(for: TipJar.productIDs)
        #expect(products.count == 3)
        #expect(products.allSatisfy { $0.type == .consumable })
    }

    @Test("A tip finishes its transaction, shows the thank-you and unlocks nothing")
    func purchaseFinishesAndThanks() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.tips.first)

        await jar.purchase(tip)

        #expect(jar.outcome == .thanked(tipName: tip.name))
        #expect(jar.state == .ready)
        try await settles("the session records the tip") { session.allTransactions().count == 1 }
        let transactions = session.allTransactions()
        #expect(transactions.count == 1)
        #expect(transactions.first?.productIdentifier == tip.id)
        #expect(transactions.first?.pendingAskToBuyConfirmation == false)
        // Finished: StoreKit has nothing left to hand out, and a consumable is never an entitlement.
        try await settles("StoreKit has no unfinished transaction") {
            var unfinished = 0
            for await _ in Transaction.unfinished { unfinished += 1 }
            return unfinished == 0
        }
        var entitlements = 0
        for await _ in Transaction.currentEntitlements { entitlements += 1 }
        #expect(entitlements == 0)
    }

    @Test("The same tip can be left again")
    func tipsAreRepeatable() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.tips.last)
        await jar.purchase(tip)
        jar.dismissOutcome()
        #expect(jar.outcome == nil)
        await jar.purchase(tip)
        #expect(jar.outcome == .thanked(tipName: tip.name))
        #expect(jar.state == .ready)
        try await settles("the session records both tips") { session.allTransactions().count == 2 }
    }

    @Test("A failed purchase says so and thanks no one")
    func failedPurchase() async throws {
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.tips.first)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)

        await jar.purchase(tip)
        try await session.setSimulatedError(nil, forAPI: .purchase)

        guard case .failed = jar.outcome else {
            Issue.record("expected a failure, got \(String(describing: jar.outcome))")
            return
        }
        #expect(session.allTransactions().isEmpty)
    }

    @Test("Ask to Buy waits, then thanks once approved")
    func askToBuy() async throws {
        session.askToBuyEnabled = true
        defer { session.askToBuyEnabled = false }
        let jar = TipJar()
        await jar.load()
        let tip = try #require(jar.tips.first)

        await jar.purchase(tip)
        #expect(jar.state == .pending)

        try await settles("the session records the request") { !session.allTransactions().isEmpty }
        let pending = try #require(session.allTransactions().first)
        #expect(jar.outcome == nil)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        // The approval arrives on `Transaction.updates`; wait for the outcome it sets, however long that takes.
        var outcome: TipJar.Outcome?
        for await next in Observations({ jar.outcome }) where next != nil {
            outcome = next
            break
        }
        #expect(outcome == .thanked(tipName: tip.name))
        #expect(jar.state == .ready)
    }

    /// StoreKit's daemon and the session's own record catch up with a purchase a moment after `purchase()` and
    /// `finish()` return; under load the first read can still show the state before (issue #93). Re-reads until
    /// `condition` holds, with no deadline of its own: the suite's time limit fails a state that never comes, and
    /// the cancellation names it.
    private func settles(_ what: String, _ condition: () async -> Bool) async throws {
        while await !condition() {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                Issue.record("never settled: \(what)")
                throw error
            }
        }
    }
}
