import Foundation
import LensSession
import Testing
@testable import BirdJournal

// A friend's notable find as the lens shows it (issue #67): the push's find summary (#63) to the banner, and the relay
// from the push center's stream to the lenses. The banner's show, hold, replace, expire and dismiss rules are the
// state machine's (LensStateMachineTests); the Mock Device Kit smoke test sends one to a mock Display.
@Suite("Friend banner")
@MainActor
struct FriendBannerTests {
    static func find(ownerName: String?, method: String = "heard", place: String? = "Pasadena") -> FriendFind {
        FriendFind(
            owner: "maya", ownerName: ownerName, sightingID: "s1", speciesID: "sayornis_nigricans", scientificName: "Sayornis nigricans",
            commonName: "Black Phoebe", method: method, place: place, foundAt: .now, newPatch: true, rarity: nil, circleFirst: false,
            circleIDs: []
        )
    }

    @Test("the banner names the friend by first name, heard or saw, the species and the place")
    func banner() {
        #expect(Self.find(ownerName: "Maya Ortiz").lensBanner.text == "Maya heard a Black Phoebe · Pasadena")
        #expect(Self.find(ownerName: "Maya", method: "seen", place: nil).lensBanner.text == "Maya saw a Black Phoebe")
        #expect(Self.find(ownerName: nil, place: "a secret spot").lensBanner.text == "A friend heard a Black Phoebe · a secret spot")
        #expect(Self.find(ownerName: "  ").lensBanner.friendName == "A friend")
    }

    @Test("one find is one banner: the friend and their sighting")
    func identity() {
        #expect(Self.find(ownerName: "Maya").lensBanner.id == Self.find(ownerName: "Maya Ortiz").lensBanner.id)
        var other = Self.find(ownerName: "Maya")
        other.sightingID = "s2"
        #expect(other.lensBanner.id != Self.find(ownerName: "Maya").lensBanner.id)
    }

    @Test("a notable push reaches the lenses through the relay; a lens with no run drops it")
    func relayDropsWithoutRun() async throws {
        let pushes = PushCenter(
            account: FakeAccount.session(signedIn: true), client: nil,
            authorizer: FakeNotificationAuthorizer(permission: .authorized), environment: .sandbox,
            defaults: UserDefaults(suiteName: "FriendBannerTests-\(UUID().uuidString)")!, explanationDelay: .zero,
            registerForRemoteNotifications: {}
        )
        let lens = GlassesLensSession()
        var asked = 0
        let relay = FriendBanners.forward(pushes.friendFinds()) {
            asked += 1
            return [lens]
        }
        defer { relay.cancel() }
        await pushes.received(FriendBanners.samplePush())
        try await waitUntil { asked == 1 }
        #expect(lens.page == .list)
        #expect(lens.machine.heldBanner == nil)
    }

    /// Long, since it only bounds a failure: other tests' pixel work and start-up hold the main actor this test polls on for seconds at a time.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
