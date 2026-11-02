import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #62: finds over HTTP (put, delete, the paged feed), the store's feed pages, and what a feed row says.

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

private let itemJSON = """
{"sighting_id":"6f9619ff-8b86-d011-b42d-00c04fc964ff","species_id":"Sayornis nigricans_Black Phoebe",
 "scientific_name":"Sayornis nigricans","common_name":"Black Phoebe","method":"seen","place":"Pasadena",
 "found_at":"2026-11-01T08:15:00Z","legendary":true,"rarity":"rare",
 "art":{"kind":"pack","key":"packs/us-ca-la/sayornis-nigricans.jpg","url":"https://d111.cloudfront.net/packs/us-ca-la/sayornis-nigricans.jpg"},
 "owner":{"id":"maya","display_name":"Maya Ortiz"},"circle_first":true,"is_mine":false}
"""

@Suite("Finds over HTTP")
struct FindClientTests {
    @Test("a find is put as the policy's JSON under the sighting's id, and deleted the same way")
    func putAndDelete() async throws {
        let recorder = Recorder()
        recorder.responses = [http(201, "{}"), http(204, "")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let find = try #require(FindPolicy.find(for: FindPolicyTests.input(), sharing: .automatic))
        try await client.putFind(find, sightingID: FindPolicyTests.identifier, accessToken: "t-1")
        try await client.deleteFind(sightingID: FindPolicyTests.identifier, accessToken: "t-1")

        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == [
            "PUT /v1/finds/6f9619ff-8b86-d011-b42d-00c04fc964ff",
            "DELETE /v1/finds/6f9619ff-8b86-d011-b42d-00c04fc964ff",
        ])
        let put = recorder.requests[0]
        #expect(put.value(forHTTPHeaderField: "Authorization") == "Bearer t-1")
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(FindPolicy.Find.self, from: put.httpBody ?? Data())
        #expect(sent == find)
    }

    @Test("the feed is read a page at a time and decodes the API's items")
    func feed() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"items":[\#(itemJSON)],"next_cursor":"abc"}"#), http(200, #"{"items":[],"next_cursor":null}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let first = try await client.feed(circleID: "c1", cursor: nil, accessToken: "t")
        let next = try await client.feed(circleID: "c1", cursor: "abc", accessToken: "t")

        #expect(recorder.requests.map { $0.url!.absoluteString } == [
            "https://api.example.com/v1/circles/c1/feed?limit=20",
            "https://api.example.com/v1/circles/c1/feed?limit=20&cursor=abc",
        ])
        #expect(first.nextCursor == "abc")
        #expect(next.items.isEmpty && next.nextCursor == nil)
        let item = try #require(first.items.first)
        #expect(item.commonName == "Black Phoebe")
        #expect(item.method == .seen)
        #expect(item.rarity == .rare)
        #expect(item.legendary && item.circleFirst && !item.isMine)
        #expect(item.owner.name == "Maya Ortiz")
        #expect(item.art?.url == URL(string: "https://d111.cloudfront.net/packs/us-ca-la/sayornis-nigricans.jpg"))
        #expect(item.foundAt == Date(timeIntervalSince1970: 1_793_520_900))
    }

    @Test("a refused find maps to the circle errors the outbox reads")
    func refusals() async {
        let recorder = Recorder()
        recorder.responses = [http(422, #"{"detail":[{"msg":"place_has_coordinate"}]}"#), http(401, "{}"), http(503, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let find = FindPolicy.find(for: FindPolicyTests.input(), sharing: .automatic)!
        await #expect(throws: CircleError.rejected) { try await client.putFind(find, sightingID: UUID(), accessToken: "t") }
        await #expect(throws: CircleError.unauthorized) { try await client.deleteFind(sightingID: UUID(), accessToken: "t") }
        await #expect(throws: CircleError.server(503)) { try await client.feed(circleID: "c", cursor: nil, accessToken: "t") }
    }
}

@Suite("A feed row")
struct FindRowTests {
    static func item(legendary: Bool = false, first: Bool = false, rarity: RarityLabel? = .common, mine: Bool = false, place: String? = "Pasadena") -> FeedItem {
        FeedItem(
            sightingID: "s", speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .heard, place: place, foundAt: .now.addingTimeInterval(-7200), legendary: legendary, rarity: rarity, art: nil,
            owner: .init(id: "maya", displayName: "Maya Ortiz"), circleFirst: first, isMine: mine
        )
    }

    @Test("it names the finder and how they met the bird")
    func byline() {
        #expect(FindRow.byline(Self.item()) == "Heard by Maya Ortiz")
        #expect(FindRow.byline(Self.item(mine: true)) == "Heard by you")
    }

    @Test("it says where, or a secret spot, and when")
    func whereAndWhen() {
        #expect(FindRow.whereAndWhen(Self.item()).hasPrefix("Pasadena · "))
        #expect(FindRow.whereAndWhen(Self.item(place: FindPolicy.secretSpot)).hasPrefix("At a secret spot · "))
        #expect(!FindRow.whereAndWhen(Self.item(place: nil)).contains("·"))
    }

    @Test("Legendary, First for the circle and Rare or Exceptional are marked; Common and Uncommon aren't")
    func marks() {
        #expect(FindRow.marks(Self.item()) == [])
        #expect(FindRow.marks(Self.item(rarity: .uncommon)) == [])
        #expect(FindRow.marks(Self.item(legendary: true, first: true, rarity: .exceptional)) == ["Legendary", "First for the circle", "Exceptional"])
        #expect(FindRow.marks(Self.item(first: true, rarity: .rare)) == ["First for the circle", "Rare"])
    }
}

#if DEBUG
@Suite("The circle feed")
@MainActor
struct CircleFeedStoreTests {
    private func store(seeded: Bool) -> (CircleStore, FakeCircleClient) {
        let client = FakeCircleClient(seeded: seeded)
        return (CircleStore(account: FakeAccount.session(signedIn: true), client: client), client)
    }

    @Test("a circle's feed loads newest first with circle firsts, and clears on sign-out")
    func loads() async throws {
        let (store, _) = store(seeded: true)
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        await store.loadFeed(circleID: sunday.id)
        let feed = try #require(store.feeds[sunday.id])
        #expect(feed.isLoaded)
        #expect(feed.items.map(\.commonName) == ["California Gnatcatcher", "Black Phoebe", "Anna's Hummingbird", "Black Phoebe", "Acorn Woodpecker", "House Finch"])
        #expect(feed.items.map(\.circleFirst) == [true, false, true, true, true, true], "Maya's earlier Black Phoebe is the circle's first")
        #expect(feed.items.first?.place == "a secret spot")
        store.clear()
        #expect(store.feeds.isEmpty)
    }

    @Test("an add on one phone appears in the circle feed, in every circle the finder was in")
    func addAppears() async throws {
        let (store, client) = store(seeded: true)
        await store.refresh()
        let find = try #require(FindPolicy.find(for: FindPolicyTests.input(), sharing: .automatic))
        try await client.putFind(find, sightingID: FindPolicyTests.identifier, accessToken: "t")
        for circle in store.circles {
            await store.loadFeed(circleID: circle.id)
            let mine = store.feeds[circle.id]?.items.filter(\.isMine) ?? []
            #expect(mine.map(\.sightingID) == [FindPolicyTests.identifier.uuidString.lowercased()], "\(circle.name)")
        }
        try await client.deleteFind(sightingID: FindPolicyTests.identifier, accessToken: "t")
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        await store.loadFeed(circleID: sunday.id)
        #expect(store.feeds[sunday.id]?.items.contains(where: \.isMine) == false)
    }

    @Test("more finds load a page at a time until the last")
    func pages() async throws {
        let (store, client) = store(seeded: false)
        let circle = try await store.create(named: "Big Day")
        for minute in 0..<25 {
            var input = FindPolicyTests.input()
            input.confirmedAt = FindPolicyTests.confirmedAt.addingTimeInterval(Double(minute) * 60)
            try await client.putFind(FindPolicy.find(for: input, sharing: .automatic)!, sightingID: UUID(), accessToken: "t")
        }
        await store.loadFeed(circleID: circle.circle.id)
        #expect(store.feeds[circle.circle.id]?.items.count == 20)
        #expect(store.feeds[circle.circle.id]?.nextCursor != nil)
        await store.loadMoreFeed(circleID: circle.circle.id)
        let feed = try #require(store.feeds[circle.circle.id])
        #expect(feed.items.count == 25)
        #expect(feed.nextCursor == nil)
        #expect(feed.items.map(\.foundAt) == feed.items.map(\.foundAt).sorted(by: >), "newest first across pages")
        #expect(feed.items.filter(\.circleFirst).count == 1, "one species, one first")
    }
}
#endif
