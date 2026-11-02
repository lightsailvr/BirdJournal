import Foundation
import Testing
import UIKit
@testable import BirdJournal

// Issue #61: circles. The HTTP client against canned API answers, invite links and their QR codes, and the store over
// the debug fake with the account's token handling.

private let api = URL(string: "https://api.example.com")!

private func http(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: api, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private final class Recorder {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func transport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return responses.isEmpty ? http(500, "{}") : responses.removeFirst()
    }
}

private let circleJSON = """
{"id":"c1","name":"Sunday Group","created_by":"sub-1","created_at":"2026-11-01T09:30:00Z","time_zone":"America/Los_Angeles",
 "member_count":2,"is_creator":true,
 "members":[{"id":"sub-1","display_name":"Ada","joined_at":"2026-11-01T09:30:00Z","is_creator":true},
            {"id":"sub-2","display_name":null,"joined_at":"2026-11-01T11:30:00Z","is_creator":false}]}
"""

@Suite("The circle client")
struct HTTPCircleClientTests {
    @Test("creating a circle posts its name and the device's time zone with the bearer token")
    func create() async throws {
        let recorder = Recorder()
        recorder.responses = [http(201, circleJSON)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let detail = try await client.createCircle(named: "Sunday Group", timeZone: "America/Los_Angeles", accessToken: "t-1")
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/circles")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t-1")
        let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
        #expect(body == ["name": "Sunday Group", "time_zone": "America/Los_Angeles"])
        #expect(detail.circle.name == "Sunday Group")
        #expect(detail.circle.isCreator)
        #expect(detail.members.map(\.id) == ["sub-1", "sub-2"])
        #expect(detail.members[1].name == "A birder")
        #expect(detail.members[0].initials == "A")
    }

    @Test("the list, an invite, its preview and accepting it decode from the API's JSON")
    func reads() async throws {
        let recorder = Recorder()
        let summary = #"{"id":"c1","name":"Family","created_by":"x","created_at":"2026-11-01T09:30:00Z","time_zone":"UTC","member_count":3,"is_creator":false}"#
        recorder.responses = [
            http(200, #"{"circles":[\#(summary)]}"#),
            http(201, #"{"token":"tok_1","url":"https://birdquest.matthewcelia.com/i/tok_1","expires_at":"2026-11-08T09:30:00Z"}"#),
            http(200, #"{"circle":\#(summary),"invited_by":"Robin","expires_at":"2026-11-08T09:30:00Z","already_member":false}"#),
            http(200, circleJSON),
            http(204, ""),
            http(204, ""),
        ]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let circles = try await client.circles(accessToken: "t")
        #expect(circles.map(\.name) == ["Family"])
        let invite = try await client.createInvite(circleID: "c1", accessToken: "t")
        #expect(invite.url == InviteLink.url(token: "tok_1"))
        #expect(invite.expiresAt == Date(timeIntervalSince1970: 1_794_130_200))
        let preview = try await client.invitePreview(token: "tok_1", accessToken: "t")
        #expect(preview.invitedBy == "Robin")
        #expect(!preview.alreadyMember)
        _ = try await client.acceptInvite(token: "tok_1", accessToken: "t")
        try await client.leave(circleID: "c1", accessToken: "t")
        try await client.removeMember("sub-2", circleID: "c1", accessToken: "t")
        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == [
            "GET /v1/circles",
            "POST /v1/circles/c1/invites",
            "GET /v1/invites/tok_1",
            "POST /v1/invites/tok_1/accept",
            "DELETE /v1/circles/c1/members/me",
            "DELETE /v1/circles/c1/members/sub-2",
        ])
    }

    @Test("the API's refusals map to circle errors", arguments: [
        (401, #"{"detail":"A valid bearer token is required"}"#, CircleError.unauthorized),
        (403, #"{"detail":"creator_only"}"#, .creatorOnly),
        (403, #"{"detail":"invite_revoked"}"#, .inviteRevoked),
        (404, #"{"detail":"not_found"}"#, .notFound),
        (409, #"{"detail":"circle_full"}"#, .full),
        (410, #"{"detail":"invite_expired"}"#, .inviteExpired),
        (422, #"{"detail":[{"msg":"too long"}]}"#, .rejected),
        (502, "", .server(502)),
    ])
    func refusals(status: Int, body: String, error: CircleError) async {
        let recorder = Recorder()
        recorder.responses = [http(status, body)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        await #expect(throws: error) { try await client.acceptInvite(token: "t", accessToken: "a") }
    }
}

@Suite("Invite links and QR codes")
struct InviteLinkTests {
    @Test("an invite link gives its token")
    func token() {
        #expect(InviteLink.token(from: URL(string: "https://birdquest.matthewcelia.com/i/AbC-d_12")!) == "AbC-d_12")
        #expect(InviteLink.token(from: InviteLink.url(token: "xyz")) == "xyz")
    }

    @Test("other links are not invites", arguments: [
        "https://birdquest.matthewcelia.com/",
        "https://birdquest.matthewcelia.com/i/",
        "https://birdquest.matthewcelia.com/i/a/b",
        "https://birdquest.matthewcelia.com/x/abc",
        "http://birdquest.matthewcelia.com/i/abc",
        "https://example.com/i/abc",
        "birdjournal://auth/callback?code=1",
        "https://birdquest.matthewcelia.com/i/a%20b",
    ])
    func notInvites(link: String) {
        #expect(InviteLink.token(from: URL(string: link)!) == nil)
    }

    @Test("the QR code encodes the same URL as the link")
    func qrRoundTrip() throws {
        let url = InviteLink.url(token: "Zx81_aB-cD3eF4gH5iJ6kL")
        let image = try #require(InviteQRCode.image(for: url))
        #expect(image.size.width >= 240)
        #expect(InviteQRCode.decode(image) == url.absoluteString)
    }
}

// The store tests run over the DEBUG fakes.
#if DEBUG
@MainActor
private func signedInStore(seeded: Bool = false) -> CircleStore {
    let account = FakeAccount.session(signedIn: true)
    return CircleStore(account: account, client: FakeCircleClient(seeded: seeded), timeZone: { "Europe/London" })
}

/// Refuses the first call with a 401, then passes calls on to the fake.
private final class RefusingClient: CircleClient {
    let inner = FakeCircleClient(seeded: false)
    var refuseNext = 1
    var tokens: [String] = []

    private func check(_ token: String) throws {
        tokens.append(token)
        if refuseNext > 0 { refuseNext -= 1; throw CircleError.unauthorized }
    }

    func circles(accessToken: String) async throws -> [CircleSummary] { try check(accessToken); return try await inner.circles(accessToken: accessToken) }
    func createCircle(named name: String, timeZone: String, accessToken: String) async throws -> CircleDetail { try check(accessToken); return try await inner.createCircle(named: name, timeZone: timeZone, accessToken: accessToken) }
    func circle(id: String, accessToken: String) async throws -> CircleDetail { try check(accessToken); return try await inner.circle(id: id, accessToken: accessToken) }
    func createInvite(circleID: String, accessToken: String) async throws -> CircleInvite { try check(accessToken); return try await inner.createInvite(circleID: circleID, accessToken: accessToken) }
    func invitePreview(token: String, accessToken: String) async throws -> InvitePreview { try check(accessToken); return try await inner.invitePreview(token: token, accessToken: accessToken) }
    func acceptInvite(token: String, accessToken: String) async throws -> CircleDetail { try check(accessToken); return try await inner.acceptInvite(token: token, accessToken: accessToken) }
    func leave(circleID: String, accessToken: String) async throws { try check(accessToken); try await inner.leave(circleID: circleID, accessToken: accessToken) }
    func removeMember(_ memberID: String, circleID: String, accessToken: String) async throws { try check(accessToken); try await inner.removeMember(memberID, circleID: circleID, accessToken: accessToken) }
    func putFind(_ find: FindPolicy.Find, sightingID: UUID, accessToken: String) async throws { try check(accessToken); try await inner.putFind(find, sightingID: sightingID, accessToken: accessToken) }
    func deleteFind(sightingID: UUID, accessToken: String) async throws { try check(accessToken); try await inner.deleteFind(sightingID: sightingID, accessToken: accessToken) }
    func feed(circleID: String, cursor: String?, accessToken: String) async throws -> FeedPage { try check(accessToken); return try await inner.feed(circleID: circleID, cursor: cursor, accessToken: accessToken) }
    func shareCard(_ card: FindPolicy.Card, sightingID: UUID, accessToken: String) async throws { try check(accessToken); try await inner.shareCard(card, sightingID: sightingID, accessToken: accessToken) }
    func photoUpload(sightingID: UUID, accessToken: String) async throws -> PhotoUpload { try check(accessToken); return try await inner.photoUpload(sightingID: sightingID, accessToken: accessToken) }
    func uploadPhoto(_ jpeg: Data, to upload: PhotoUpload) async throws { try await inner.uploadPhoto(jpeg, to: upload) }
    func registerDevice(token: String, environment: PushEnvironment, accessToken: String) async throws { try check(accessToken); try await inner.registerDevice(token: token, environment: environment, accessToken: accessToken) }
    func unregisterDevice(token: String, accessToken: String) async throws { try check(accessToken); try await inner.unregisterDevice(token: token, accessToken: accessToken) }
    func mutes(accessToken: String) async throws -> Mutes { try check(accessToken); return try await inner.mutes(accessToken: accessToken) }
    func setCircleMuted(_ muted: Bool, circleID: String, accessToken: String) async throws { try check(accessToken); try await inner.setCircleMuted(muted, circleID: circleID, accessToken: accessToken) }
    func setFriendMuted(_ muted: Bool, friendID: String, accessToken: String) async throws { try check(accessToken); try await inner.setFriendMuted(muted, friendID: friendID, accessToken: accessToken) }
    func goals(circleID: String, accessToken: String) async throws -> [CircleGoal] { try check(accessToken); return try await inner.goals(circleID: circleID, accessToken: accessToken) }
    func createGoal(_ draft: GoalDraft, circleID: String, accessToken: String) async throws -> CircleGoal { try check(accessToken); return try await inner.createGoal(draft, circleID: circleID, accessToken: accessToken) }
    func deleteGoal(id: String, circleID: String, accessToken: String) async throws { try check(accessToken); try await inner.deleteGoal(id: id, circleID: circleID, accessToken: accessToken) }
    func setReaction(_ kind: ReactionKind, given: Bool, owner: String, sightingID: String, accessToken: String) async throws -> [ReactionCount] { try check(accessToken); return try await inner.setReaction(kind, given: given, owner: owner, sightingID: sightingID, accessToken: accessToken) }
    func compare(friendID: String, accessToken: String) async throws -> FriendBirds { try check(accessToken); return try await inner.compare(friendID: friendID, accessToken: accessToken) }
}

@Suite("The circle store")
@MainActor
struct CircleStoreTests {
    @Test("a new circle is listed at once, named as typed and trimmed")
    func createLists() async throws {
        let store = signedInStore()
        await store.refresh()
        #expect(store.circles.isEmpty)
        #expect(store.listState == .loaded)
        let detail = try await store.create(named: "  Backyard  ")
        #expect(store.circles.map(\.name) == ["Backyard"])
        #expect(store.details[detail.circle.id]?.members.map(\.id) == [FakeCircleClient.me])
        #expect(detail.circle.timeZone == "Europe/London")
    }

    @Test("joining from an invite adds the circle; leaving takes it away")
    func joinAndLeave() async throws {
        let store = signedInStore()
        let preview = try await store.preview(token: "fake-invite")
        #expect(preview.circle.name == "Canyon Walkers")
        let joined = try await store.accept(token: "fake-invite")
        #expect(store.circles.map(\.name) == ["Canyon Walkers"])
        try await store.leave(circleID: joined.circle.id)
        #expect(store.circles.isEmpty)
        await store.refresh()
        #expect(store.circles.isEmpty)
    }

    @Test("an expired invitation and a full circle say why")
    func refusals() async {
        let store = signedInStore()
        await #expect(throws: CircleError.inviteExpired) { try await store.preview(token: "expired") }
        await #expect(throws: CircleError.full) { try await store.accept(token: "full") }
        #expect(CircleStore.message(for: CircleError.full, doing: "join") == "This circle is full: a circle holds 20 birders.")
        #expect(store.circles.isEmpty)
    }

    @Test("only the creator removes a member")
    func removal() async throws {
        let store = signedInStore(seeded: true)
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        let family = try #require(store.circles.first { $0.name == "Family" })
        try await store.remove(memberID: "maya", circleID: sunday.id)
        #expect(store.details[sunday.id]?.members.map(\.id).contains("maya") == false)
        await #expect(throws: CircleError.creatorOnly) { try await store.remove(memberID: "lee", circleID: family.id) }
    }

    @Test("a refused token is renewed once and the circle call retried, as for the account")
    func retry() async throws {
        let client = RefusingClient()
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        try await store.create(named: "Retry")
        #expect(client.tokens.count == 2)
        #expect(store.circles.map(\.name) == ["Retry"])
    }

    @Test("signed out, the store reads nothing and keeps nothing")
    func signedOut() async {
        let store = CircleStore(account: FakeAccount.session(signedIn: false), client: FakeCircleClient(seeded: true))
        await store.refresh()
        #expect(store.circles.isEmpty)
        #expect(store.listState == .idle)
    }

    @Test("without a server the build has no circles")
    func unavailable() {
        let account = AccountSession(auth: nil, api: nil, store: InMemoryTokenStore())
        #expect(!CircleStore(account: account, client: nil).isAvailable)
        #expect(!CircleStore(account: account, client: FakeCircleClient(seeded: false)).isAvailable)
    }
}
#endif
