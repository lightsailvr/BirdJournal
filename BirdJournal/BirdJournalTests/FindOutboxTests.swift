import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #62: the outbox of find puts and deletes. An offline add publishes once online, a delete after publishing
// removes the find, signing out stops publishing, and what waits survives a relaunch and a failing server.
#if DEBUG
/// Records the finds sent; the other circle calls go to the in-memory fake.
private final class FindRecorder: CircleClient {
    private let inner = FakeCircleClient(seeded: false)
    var calls: [String] = []
    var puts: [UUID: FindPolicy.Find] = [:]
    /// Thrown by the next find call, then cleared.
    var failNext: Error?

    private func record(_ call: String) throws {
        if let error = failNext {
            failNext = nil
            calls.append("failed \(call)")
            throw error
        }
        calls.append(call)
    }

    func putFind(_ find: FindPolicy.Find, sightingID: UUID, accessToken: String) async throws {
        try record("put \(sightingID)")
        puts[sightingID] = find
    }

    func deleteFind(sightingID: UUID, accessToken: String) async throws {
        try record("delete \(sightingID)")
        puts[sightingID] = nil
    }

    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage { FeedPage(items: [], nextCursor: nil) }
    func circles(accessToken: String) async throws -> [CircleSummary] { try await inner.circles(accessToken: accessToken) }
    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail { try await inner.createCircle(named: name, timeZone: timeZone, accessToken: accessToken) }
    func circle(id: String, accessToken: String) async throws -> CircleDetail { try await inner.circle(id: id, accessToken: accessToken) }
    func createInvite(circleID: String, accessToken: String) async throws -> CircleInvite { try await inner.createInvite(circleID: circleID, accessToken: accessToken) }
    func invitePreview(token: String, accessToken: String) async throws -> InvitePreview { try await inner.invitePreview(token: token, accessToken: accessToken) }
    func acceptInvite(token: String, accessToken: String) async throws -> CircleDetail { try await inner.acceptInvite(token: token, accessToken: accessToken) }
    func leave(circleID: String, accessToken: String) async throws { try await inner.leave(circleID: circleID, accessToken: accessToken) }
    func removeMember(_ memberID: String, circleID: String, accessToken: String) async throws { try await inner.removeMember(memberID, circleID: circleID, accessToken: accessToken) }
    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws { try await inner.registerDevice(token: token, environment: environment, accessToken: accessToken) }
    func unregisterDevice(token: String, accessToken: String) async throws { try await inner.unregisterDevice(token: token, accessToken: accessToken) }
    func mutes(accessToken: String) async throws -> Mutes { try await inner.mutes(accessToken: accessToken) }
    func setCircleMuted(_ muted: Bool, circleID: String, accessToken: String) async throws { try await inner.setCircleMuted(muted, circleID: circleID, accessToken: accessToken) }
    func setFriendMuted(_ muted: Bool, friendID: String, accessToken: String) async throws { try await inner.setFriendMuted(muted, friendID: friendID, accessToken: accessToken) }
    func goals(circleID: String, accessToken: String) async throws -> [CircleGoal] { try await inner.goals(circleID: circleID, accessToken: accessToken) }
    func createGoal(_ draft: GoalDraft, circleID: String, accessToken: String) async throws -> CircleGoal { try await inner.createGoal(draft, circleID: circleID, accessToken: accessToken) }
    func deleteGoal(id: String, circleID: String, accessToken: String) async throws { try await inner.deleteGoal(id: id, circleID: circleID, accessToken: accessToken) }
}

/// Signs in as another account than the fake's `fake-sub`.
private final class OtherAuthClient: AuthClient {
    func signIn(with provider: IdentityProvider) async throws -> AuthTokens { Self.tokens }
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens { Self.tokens }
    func revoke(_ tokens: AuthTokens) async {}

    static let tokens: AuthTokens = {
        let claims = #"{"sub":"other-sub","name":"Robin"}"#
        return AuthTokens(accessToken: "other-access", idToken: "e30.\(Data(claims.utf8).base64URLEncodedString()).sig", refreshToken: "r", expiresAt: .now.addingTimeInterval(3600))
    }()
}

@MainActor
private final class Harness {
    let client = FindRecorder()
    let account: AccountSession
    var online = true
    var sharing = FindPolicy.Sharing.automatic
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// Sightings that no longer exist: their puts find nothing to send.
    var gone: Set<UUID> = []
    /// The Legendary flag each payload was built with.
    var legendaryFlags: [UUID: Bool] = [:]
    let fileURL: URL
    private(set) var outbox: FindOutbox!

    init(account: AccountSession = FakeAccount.session(signedIn: true), fileURL: URL = URL.temporaryDirectory.appending(path: "FindOutbox-\(UUID().uuidString).json")) {
        self.account = account
        self.fileURL = fileURL
        outbox = makeOutbox()
    }

    /// A new outbox over the same file: the app relaunched.
    func makeOutbox() -> FindOutbox {
        FindOutbox(
            account: account, client: client, fileURL: fileURL, sharing: { [unowned self] in sharing },
            payload: { [unowned self] identifier, legendary in
                guard !gone.contains(identifier) else { return nil }
                legendaryFlags[identifier] = legendary
                return FindPolicy.find(for: FindPolicyTests.input(isLegendary: legendary), sharing: .automatic)
            },
            isOnline: { [unowned self] in online },
            now: { [unowned self] in now }
        )
    }

    func relaunch() { outbox = makeOutbox() }
}

@Suite("Find outbox")
@MainActor
struct FindOutboxTests {
    @Test("an add made offline publishes once the phone is online, once")
    func offlineThenOnline() async {
        let harness = Harness()
        harness.online = false
        let sighting = UUID()
        harness.outbox.added(sighting, isLegendary: false)
        await harness.outbox.flush()
        #expect(harness.client.calls.isEmpty)
        #expect(harness.outbox.entries.map(\.operation) == [.put])

        harness.online = true
        await harness.outbox.flush()
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(sighting)"])
        #expect(harness.outbox.entries.isEmpty)
        #expect(harness.client.puts[sighting]?.place == "Pasadena")
    }

    @Test("a delete after publishing removes the find")
    func deleteAfterPublishing() async {
        let harness = Harness()
        let sighting = UUID()
        harness.outbox.added(sighting, isLegendary: false)
        await harness.outbox.flush()
        harness.outbox.removed(sighting)
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(sighting)", "delete \(sighting)"])
        #expect(harness.client.puts[sighting] == nil)
        #expect(harness.outbox.entries.isEmpty)

        // Undo after the delete went: the find comes back.
        harness.outbox.restored(sighting)
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(sighting)", "delete \(sighting)", "put \(sighting)"])
    }

    @Test("signing out stops publishing; signing back in sends what waited")
    func signingOutStops() async {
        let harness = Harness()
        harness.online = false
        let before = UUID()
        harness.outbox.added(before, isLegendary: false)
        harness.account.signOut()
        harness.online = true
        await harness.outbox.flush()
        #expect(harness.client.calls.isEmpty, "signed out, nothing goes")

        let signedOutAdd = UUID()
        harness.outbox.added(signedOutAdd, isLegendary: false)
        #expect(harness.outbox.entries.map(\.identifier) == [before], "an add while signed out is never published")

        await harness.account.signIn(with: .apple)
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(before)"])
    }

    @Test("another account never sends the first one's finds")
    func otherAccount() async {
        let harness = Harness(account: AccountSession(auth: OtherAuthClient(), api: FakeAccountAPI(), store: InMemoryTokenStore(nil)))
        await harness.account.signIn(with: .google)
        harness.online = false
        let theirs = UUID()
        harness.outbox.added(theirs, isLegendary: false)
        #expect(harness.outbox.entries.map(\.owner) == ["other-sub"])

        let mine = Harness(account: FakeAccount.session(signedIn: true), fileURL: harness.fileURL)
        await mine.outbox.flush()
        #expect(mine.client.calls.isEmpty)
        #expect(mine.outbox.entries.map(\.owner) == ["other-sub"], "kept for its own account")
    }

    @Test("a private birder's adds queue nothing, and turning sharing on later doesn't publish them")
    func privateAdds() async {
        let harness = Harness()
        harness.sharing = .private
        let quiet = UUID()
        harness.outbox.added(quiet, isLegendary: true)
        harness.sharing = .automatic
        harness.outbox.changed(quiet)
        harness.outbox.removed(quiet)
        await harness.outbox.flush()
        #expect(harness.client.calls.isEmpty)
        #expect(harness.outbox.entries.isEmpty && harness.outbox.published.isEmpty)
    }

    @Test("Heard to Seen puts a published find again, with the Legendary flag of its add")
    func repeatedPut() async {
        let harness = Harness()
        let sighting = UUID()
        harness.outbox.added(sighting, isLegendary: true)
        await harness.outbox.flush()
        harness.outbox.changed(sighting)
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(sighting)", "put \(sighting)"])
        #expect(harness.legendaryFlags[sighting] == true)
    }

    @Test("a removal undone before it is sent sends only the put")
    func coalesced() async {
        let harness = Harness()
        harness.online = false
        let sighting = UUID()
        harness.outbox.added(sighting, isLegendary: false)
        harness.outbox.removed(sighting)
        #expect(harness.outbox.entries.map(\.operation) == [.delete])
        harness.outbox.restored(sighting)
        harness.online = true
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(sighting)"])
    }

    @Test("what waits survives a relaunch")
    func persisted() async {
        let harness = Harness()
        harness.online = false
        let added = UUID()
        let published = UUID()
        harness.online = true
        harness.outbox.added(published, isLegendary: false)
        await harness.outbox.flush()
        harness.online = false
        harness.outbox.added(added, isLegendary: true)
        harness.outbox.removed(published)

        harness.relaunch()
        #expect(harness.outbox.entries.map(\.identifier) == [added, published])
        harness.online = true
        await harness.outbox.flush()
        #expect(harness.client.calls == ["put \(published)", "put \(added)", "delete \(published)"])
        #expect(harness.legendaryFlags[added] == true)
    }

    @Test("a failing send retries with backoff; a refused one is dropped")
    func retries() async {
        let harness = Harness()
        harness.online = false
        let flaky = UUID()
        harness.outbox.added(flaky, isLegendary: false)
        harness.client.failNext = URLError(.timedOut)
        harness.online = true
        await harness.outbox.flush()
        #expect(harness.client.calls == ["failed put \(flaky)"])
        #expect(harness.outbox.entries.first?.attempts == 1)
        #expect(harness.outbox.entries.first?.retryAfter == harness.now.addingTimeInterval(2))

        await harness.outbox.flush()
        #expect(harness.client.calls.count == 1, "not before the backoff")
        harness.now = harness.now.addingTimeInterval(3)
        await harness.outbox.flush()
        #expect(harness.client.calls.last == "put \(flaky)")
        #expect(harness.outbox.entries.isEmpty)

        let refused = UUID()
        harness.client.failNext = CircleError.rejected
        harness.outbox.added(refused, isLegendary: false)
        await harness.outbox.flush()
        #expect(harness.client.calls.last == "failed put \(refused)")
        #expect(harness.outbox.entries.isEmpty, "a find the server refuses never will be taken")
    }

    @Test("the backoff doubles up to five minutes, and only refusals a retry can't fix are permanent")
    func backoffAndPermanence() {
        #expect([1, 2, 3, 8, 9, 40].map(FindOutbox.backoff(afterAttempts:)) == [2, 4, 8, 256, 300, 300])
        #expect(FindOutbox.isPermanent(CircleError.rejected))
        #expect(FindOutbox.isPermanent(CircleError.server(400)))
        #expect(!FindOutbox.isPermanent(CircleError.server(429)))
        #expect(!FindOutbox.isPermanent(CircleError.server(503)))
        #expect(!FindOutbox.isPermanent(URLError(.notConnectedToInternet)))
    }

    @Test("a put whose sighting is gone is dropped")
    func goneSighting() async {
        let harness = Harness()
        harness.online = false
        let sighting = UUID()
        harness.outbox.added(sighting, isLegendary: false)
        harness.gone.insert(sighting)
        harness.online = true
        await harness.outbox.flush()
        #expect(harness.client.calls.isEmpty)
        #expect(harness.outbox.entries.isEmpty)
    }
}
#endif
