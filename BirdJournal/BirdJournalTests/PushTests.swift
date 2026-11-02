import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #63: pushes on the phone. The device and mute routes, the provisioning profile's environment, what a push's
// payload says, and the push center over the debug fakes: permission asked once at the first circle, a denial, the
// token following the account, and what an arriving push does.

private let api = URL(string: "https://api.example.com")!
private let token = String(repeating: "ab", count: 32)

private func http(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: api, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private final class Recorder {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return responses.isEmpty ? http(204, "") : responses.removeFirst()
    }
}

@Suite("The push routes")
struct PushRouteTests {
    @Test("a device registers with its environment and leaves with a delete")
    func devices() async throws {
        let recorder = Recorder()
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        try await client.registerDevice(token: token, environment: .production, accessToken: "t")
        try await client.unregisterDevice(token: token, accessToken: "t")
        let (put, delete) = (recorder.requests[0], recorder.requests[1])
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.absoluteString == "https://api.example.com/v1/account/devices/\(token)")
        #expect(try JSONDecoder().decode([String: String].self, from: put.httpBody ?? Data()) == ["environment": "production"])
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path() == "/v1/account/devices/\(token)")
    }

    @Test("mutes are read, and set and cleared per circle and per friend")
    func mutes() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"circles":["c1"],"friends":["maya"]}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        #expect(try await client.mutes(accessToken: "t") == Mutes(circles: ["c1"], friends: ["maya"]))
        try await client.setCircleMuted(true, circleID: "c1", accessToken: "t")
        try await client.setCircleMuted(false, circleID: "c1", accessToken: "t")
        try await client.setFriendMuted(true, friendID: "maya", accessToken: "t")
        try await client.setFriendMuted(false, friendID: "maya", accessToken: "t")
        #expect(recorder.requests.dropFirst().map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "PUT /v1/circles/c1/mute", "DELETE /v1/circles/c1/mute", "PUT /v1/friends/maya/mute", "DELETE /v1/friends/maya/mute",
        ])
    }

    @Test("a refused mute maps like the circle routes")
    func refused() async throws {
        let recorder = Recorder()
        recorder.responses = [http(404, #"{"detail":"not_found"}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        await #expect(throws: CircleError.notFound) { try await client.setFriendMuted(true, friendID: "zed", accessToken: "t") }
    }
}

@Suite("The push environment and payloads")
struct PushPayloadTests {
    private func profile(_ environment: String?) -> Data {
        let entitlements = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>\(entitlements)</dict></dict></plist>
        """
        // The profile wraps the plist in a binary CMS envelope.
        return Data([0x30, 0x82, 0x01, 0x00]) + Data(plist.utf8) + Data([0x00, 0xA0])
    }

    @Test("the profile's aps-environment picks the APNs environment; no profile is sandbox")
    func environment() {
        #expect(PushEnvironment.fromProvisioningProfile(profile("development")) == .sandbox)
        #expect(PushEnvironment.fromProvisioningProfile(profile("production")) == .production)
        #expect(PushEnvironment.fromProvisioningProfile(profile(nil)) == nil)
        #expect(PushEnvironment.current(bundle: Bundle(for: Recorder.self)) == .sandbox)
    }

    @Test("a notable push carries the find for the lens banner")
    func notable() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1, "alert": ["title": "Maya found a Black Phoebe", "body": "Legendary · Pasadena"]],
            "kind": "notable",
            "find": [
                "owner": "maya", "owner_name": "Maya Ortiz", "sighting_id": "s1", "species_id": "Sayornis nigricans_Black Phoebe",
                "scientific_name": "Sayornis nigricans", "common_name": "Black Phoebe", "method": "heard", "place": "Pasadena",
                "found_at": "2026-11-01T08:15:00Z", "legendary": true, "rarity": "common", "circle_first": false, "circle_ids": ["c1"],
            ] as [String: Any],
        ]
        guard case .notable(let find) = try #require(PushMessage(userInfo: userInfo)) else {
            Issue.record("not notable")
            return
        }
        #expect(find.friendName == "Maya Ortiz")
        #expect(find.commonName == "Black Phoebe")
        #expect(find.legendary)
        #expect(find.foundAt == Date(timeIntervalSince1970: 1_793_520_900))
        #expect(PushMessage(userInfo: userInfo)?.circleIDs == ["c1"])
    }

    @Test("a digest and a silent refresh are read; anything else is not ours")
    func others() {
        #expect(PushMessage(userInfo: ["kind": "digest", "friend": "maya"]) == .digest(friend: "maya"))
        #expect(PushMessage(userInfo: ["kind": "refresh", "circle_ids": ["c1", "c2"]]) == .refresh(circleIDs: ["c1", "c2"]))
        #expect(PushMessage(userInfo: ["aps": ["alert": "hi"]]) == nil)
        #expect(PushMessage(userInfo: ["kind": "notable", "find": ["owner": "x"]]) == nil)
    }
}

#if DEBUG
@MainActor
private struct Harness {
    let account: AccountSession
    let client: FakeCircleClient
    let store: CircleStore
    let authorizer: FakeNotificationAuthorizer
    let pushes: PushCenter
    let registrations: Counter

    final class Counter { var count = 0 }

    init(permission: PushPermission = .notDetermined, grants: Bool = true, signedIn: Bool = true, seeded: Bool = false) {
        account = FakeAccount.session(signedIn: signedIn)
        client = FakeCircleClient(seeded: seeded)
        store = CircleStore(account: account, client: client, timeZone: { "UTC" })
        authorizer = FakeNotificationAuthorizer(permission: permission, grants: grants)
        let registrations = Counter()
        self.registrations = registrations
        let defaults = UserDefaults(suiteName: "PushTests-\(UUID().uuidString)")!
        pushes = PushCenter(
            account: account, client: client, authorizer: authorizer, environment: .sandbox, defaults: defaults,
            explanationDelay: .zero, registerForRemoteNotifications: { registrations.count += 1 }
        )
        store.joinedCircle = { [pushes] in await pushes.joinedCircle() }
        pushes.refresh = { [store] ids in await store.refreshAfterPush(circleIDs: ids) }
    }
}

@Suite("The push center")
@MainActor
struct PushCenterTests {
    @Test("the first circle created explains pushes once; the second asks nothing")
    func firstCircle() async throws {
        let harness = Harness()
        #expect(!harness.pushes.isExplaining)
        try await harness.store.create(named: "Sunday Group")
        #expect(harness.pushes.isExplaining)
        harness.pushes.notNow()
        try await harness.store.create(named: "Weekday Walkers")
        #expect(!harness.pushes.isExplaining)
        #expect(harness.authorizer.requests == 0)
    }

    @Test("joining a circle by an invitation explains too")
    func joining() async throws {
        let harness = Harness()
        _ = try await harness.store.accept(token: "fake-invite")
        #expect(harness.pushes.isExplaining)
    }

    @Test("signing in, opening circles or a launch never asks")
    func notElsewhere() async {
        let harness = Harness()
        await harness.store.refresh()
        await harness.pushes.refreshPermission()
        await harness.pushes.accountChanged()
        #expect(!harness.pushes.isExplaining)
        #expect(harness.authorizer.requests == 0)
    }

    @Test("allowed already, or denied already: no explanation")
    func alreadyDecided() async throws {
        for permission in [PushPermission.authorized, .denied] {
            let harness = Harness(permission: permission)
            try await harness.store.create(named: "Sunday Group")
            #expect(!harness.pushes.isExplaining)
        }
    }

    @Test("turning on asks the system, registers with APNs, and sends the token with its environment")
    func turnOn() async throws {
        let harness = Harness()
        try await harness.store.create(named: "Sunday Group")
        await harness.pushes.turnOn()
        #expect(!harness.pushes.isExplaining)
        #expect(harness.pushes.permission == .authorized)
        #expect(harness.registrations.count == 1)
        await harness.pushes.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        #expect(harness.pushes.deviceToken == token)
        #expect(harness.client.devices == [token: .sandbox])
        // iOS hands the token back on every launch; the account already has it.
        await harness.pushes.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        #expect(harness.client.deviceLog == ["register \(token) sandbox"])
    }

    @Test("a denial is kept: no registration, and the circle page offers Settings")
    func denied() async throws {
        let harness = Harness(grants: false)
        try await harness.store.create(named: "Sunday Group")
        await harness.pushes.turnOn()
        #expect(harness.pushes.permission == .denied)
        #expect(harness.registrations.count == 0)
        // Asking again never shows the system prompt twice.
        await harness.pushes.turnOn()
        #expect(harness.authorizer.requests == 1)
    }

    @Test("signed out the token waits; signing in sends it, and signing out takes it off the account")
    func followsTheAccount() async throws {
        let harness = Harness(permission: .authorized, signedIn: false)
        await harness.pushes.didRegister(deviceToken: Data(repeating: 0xab, count: 32))
        #expect(harness.client.deviceLog.isEmpty)
        await harness.account.signIn(with: .apple)
        await harness.pushes.accountChanged()
        #expect(harness.client.deviceLog == ["register \(token) sandbox"])
        harness.account.signOut()
        for _ in 0..<50 where harness.client.devices[token] != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(harness.client.deviceLog == ["register \(token) sandbox", "unregister \(token)"])
        await harness.pushes.accountChanged()
        await harness.account.signIn(with: .apple)
        await harness.pushes.accountChanged()
        #expect(harness.client.deviceLog.last == "register \(token) sandbox")
    }

    @Test("a notable push keeps the find for the lens and streams it; every push refreshes the named feeds")
    func received() async throws {
        let harness = Harness(seeded: true)
        await harness.store.refresh()
        let sunday = try #require(harness.store.circles.first { $0.name == "Sunday Group" })
        await harness.store.loadFeed(circleID: sunday.id)
        let before = harness.store.feeds[sunday.id]?.items.count ?? 0
        try await harness.client.putFind(
            FindPolicy.Find(speciesID: "a_b", scientificName: "Genus species", commonName: "Bird", method: .heard, place: nil, foundAt: "2026-11-01T08:00:00Z", legendary: true, rarity: nil, threatened: false, art: nil),
            sightingID: UUID(), accessToken: "t"
        )
        var stream = harness.pushes.friendFinds().makeAsyncIterator()
        let payload: [AnyHashable: Any] = ["kind": "notable", "find": [
            "owner": "maya", "owner_name": "Maya Ortiz", "sighting_id": "s1", "species_id": "a_b", "scientific_name": "Genus species",
            "common_name": "Bird", "method": "seen", "place": NSNull(), "found_at": "2026-11-01T08:00:00Z", "legendary": true,
            "rarity": NSNull(), "circle_first": true, "circle_ids": [sunday.id],
        ] as [String: Any]]
        await harness.pushes.received(payload)
        #expect(harness.pushes.latestFriendFind?.sightingID == "s1")
        #expect(await stream.next()?.commonName == "Bird")
        #expect(harness.store.feeds[sunday.id]?.items.count == before + 1)
    }

    @Test("tapping a push opens its circle, a digest the list")
    func opened() async {
        let harness = Harness()
        await harness.pushes.opened(["kind": "refresh", "circle_ids": ["c9"]])
        #expect(harness.pushes.pendingCircle == "c9")
        await harness.pushes.opened(["kind": "digest", "friend": "maya"])
        #expect(harness.pushes.pendingCircle == "")
    }

    @Test("mutes over the fake: a circle and a friend, kept until unmuted, cleared at sign-out")
    func mutes() async throws {
        let harness = Harness(seeded: true)
        await harness.store.refresh()
        let sunday = try #require(harness.store.circles.first { $0.name == "Sunday Group" })
        try await harness.store.setCircleMuted(true, circleID: sunday.id)
        try await harness.store.setFriendMuted(true, friendID: "maya")
        await harness.store.refresh()
        #expect(harness.store.mutes == Mutes(circles: [sunday.id], friends: ["maya"]))
        try await harness.store.setFriendMuted(false, friendID: "maya")
        #expect(harness.store.mutes.friends.isEmpty)
        await #expect(throws: CircleError.notFound) { try await harness.store.setFriendMuted(true, friendID: "stranger") }
        harness.store.clear()
        #expect(harness.store.mutes == Mutes())
    }
}
#endif
