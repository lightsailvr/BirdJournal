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
 "found_at":"2026-11-01T08:15:00Z","new_patch":true,"edition":"us-ca-sd","rarity":"rare",
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
        #expect(item.newPatch && item.circleFirst && !item.isMine)
        #expect(item.edition == "us-ca-sd")
        #expect(item.owner.name == "Maya Ortiz")
        #expect(item.art?.url == URL(string: "https://d111.cloudfront.net/packs/us-ca-la/sayornis-nigricans.jpg"))
        #expect(item.foundAt == Date(timeIntervalSince1970: 1_793_520_900))
    }

    @Test("a refused find maps to the circle errors the outbox reads")
    func refusals() async {
        let recorder = Recorder()
        // Refused twice: the new form, and the old one tried after it (`LegacyFindWire`).
        let refusal = http(422, #"{"detail":[{"msg":"place_has_coordinate"}]}"#)
        recorder.responses = [refusal, refusal, http(401, "{}"), http(503, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let find = FindPolicy.find(for: FindPolicyTests.input(), sharing: .automatic)!
        await #expect(throws: CircleError.rejected) { try await client.putFind(find, sightingID: UUID(), accessToken: "t") }
        await #expect(throws: CircleError.unauthorized) { try await client.deleteFind(sightingID: UUID(), accessToken: "t") }
        await #expect(throws: CircleError.server(503)) { try await client.feed(circleID: "c", cursor: nil, accessToken: "t") }
    }
}

// Issue #136, until the backend deploy (`LegacyFindWire`): the deployed server refuses `new_patch` (`extra="forbid"`) and
// only ever sends `legendary`. Delete this suite with the seam.
@Suite("Finds with a server from before #136")
struct LegacyFindWireTests {
    private static let refusedField = http(422, #"{"detail":[{"type":"extra_forbidden","loc":["body","new_patch"],"msg":"Extra inputs are not permitted"}]}"#)

    private static func find() throws -> FindPolicy.Find {
        var input = FindPolicyTests.input(isNewPatch: true)
        input.edition = "us-ca-la"
        return try #require(FindPolicy.find(for: input, sharing: .automatic))
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    @Test("a server that takes new_patch hears it, and only once")
    func newServer() async throws {
        let recorder = Recorder()
        recorder.responses = [http(201, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        try await client.putFind(try Self.find(), sightingID: UUID(), accessToken: "t")
        #expect(recorder.requests.count == 1)
        let body = try Self.json(recorder.requests[0])
        #expect(body["new_patch"] as? Bool == true && body["edition"] as? String == "us-ca-la" && body["legendary"] == nil)
    }

    @Test("a server that refuses new_patch gets the old form, and the find stays a new patch")
    func oldServer() async throws {
        let recorder = Recorder()
        recorder.responses = [Self.refusedField, http(201, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        try await client.putFind(try Self.find(), sightingID: UUID(), accessToken: "t")
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[0].url == recorder.requests[1].url)
        let body = try Self.json(recorder.requests[1])
        #expect(body["legendary"] as? Bool == true)
        #expect(body["new_patch"] == nil && body["edition"] == nil)
        // Every other field as before, which the old server's strict body takes.
        #expect(body.keys.sorted() == ["art", "common_name", "found_at", "legendary", "method", "place", "rarity", "scientific_name", "species_id", "threatened"])
    }

    @Test("a card shared by hand falls back the same way, its find in the old form")
    func oldServerCard() async throws {
        let recorder = Recorder()
        recorder.responses = [Self.refusedField, http(201, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let card = FindPolicy.card(for: FindPolicyTests.input(isNewPatch: true), choices: .init(), circleIDs: ["c1"], photoKey: nil)
        try await client.shareCard(card, sightingID: UUID(), accessToken: "t")
        let find = try #require(try Self.json(recorder.requests[1])["find"] as? [String: Any])
        #expect(find["legendary"] as? Bool == true && find["new_patch"] == nil)
    }

    @Test("a repeat in the old form isn't a new patch")
    func oldServerRepeat() async throws {
        let recorder = Recorder()
        recorder.responses = [Self.refusedField, http(201, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let find = try #require(FindPolicy.find(for: FindPolicyTests.input(isNewPatch: false), sharing: .automatic))
        try await client.putFind(find, sightingID: UUID(), accessToken: "t")
        #expect(try Self.json(recorder.requests[1])["legendary"] as? Bool == false)
    }

    @Test("the deployed server's feed item reads as a new patch, its edition from its patch's art key")
    func oldFeed() async throws {
        let oldItem = itemJSON
            .replacingOccurrences(of: #""new_patch":true,"edition":"us-ca-sd""#, with: #""legendary":true"#)
            .replacingOccurrences(of: "packs/us-ca-la/sayornis-nigricans.jpg", with: "packs/us-ca-la/patch/sayornis-nigricans.png")
        #expect(!oldItem.contains("new_patch"))
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"items":[\#(oldItem)],"next_cursor":null}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let item = try #require(try await client.feed(circleID: "c1", cursor: nil, accessToken: "t").items.first)
        #expect(item.newPatch)
        #expect(item.edition == "us-ca-la")
    }

    @Test("an edition comes only from a patch's key: pack art can be another set's, even for a find outside every set")
    func editionOfArtKey() {
        #expect(LegacyFindWire.edition(ofArtKey: "packs/us-ca-la/patch/x.png") == "us-ca-la")
        #expect(LegacyFindWire.edition(ofArtKey: "packs/us-ca-la/x.jpg") == nil)
        #expect(LegacyFindWire.edition(ofArtKey: "art/sub/x.jpg") == nil)
        #expect(LegacyFindWire.edition(ofArtKey: nil) == nil)
    }
}

@Suite("A feed row")
struct FindRowTests {
    static func item(newPatch: Bool = false, first: Bool = false, rarity: RarityLabel? = .common, mine: Bool = false, place: String? = "Pasadena") -> FeedItem {
        FeedItem(
            sightingID: "s", speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .heard, place: place, foundAt: .now.addingTimeInterval(-7200), newPatch: newPatch, rarity: rarity, art: nil,
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
        #expect(FindRow.whereAndWhen(Self.item()).hasPrefix("Pasadena, "))
        #expect(FindRow.whereAndWhen(Self.item(place: FindPolicy.secretSpot)).hasPrefix("At a secret spot, "))
        #expect(!FindRow.whereAndWhen(Self.item(place: nil)).contains("·"))
    }

    @Test("First for the Guild and Rare or Exceptional are marked; Common and Uncommon aren't; a new patch says so in its headline")
    func marks() {
        #expect(FindRow.marks(Self.item()) == [])
        #expect(FindRow.marks(Self.item(rarity: .uncommon)) == [])
        #expect(FindRow.marks(Self.item(newPatch: true, first: true, rarity: .exceptional)) == ["First for the Guild", "Exceptional"])
        #expect(FindRow.marks(Self.item(first: true, rarity: .rare)) == ["First for the Guild", "Rare"])
    }
}

extension FindRowTests {
    @Test("a new patch is led by the patch and says who sewed it")
    func newPatch() {
        let item = Self.item(newPatch: true, first: true)
        #expect(FindRow.isLed(item))
        #expect(FindRow.headline(item) == "Maya sewed a new patch")
        #expect(FindRow.headline(Self.item(newPatch: true, mine: true)) == "You sewed a new patch")
        #expect(FindRow.howAndWhere(item).hasPrefix("Heard in Pasadena, "))
        #expect(FindRow.spoken(item).hasPrefix("Black Phoebe. Heard by Maya Ortiz. Pasadena, "))
        #expect(FindRow.spoken(item).hasSuffix(". New patch. First for the Guild"))
    }

    @Test("a repeat is a quieter line, keeping its marks")
    func seenAgain() {
        let item = Self.item(first: true)
        #expect(!FindRow.isLed(item))
        #expect(FindRow.seenAgainLine(item).hasPrefix("Maya Ortiz heard a Black Phoebe again in Pasadena, "))
        var seen = Self.item(mine: true, place: nil)
        seen.method = .seen
        seen.commonName = "Acorn Woodpecker"
        #expect(FindRow.seenAgainLine(seen).hasPrefix("You saw an Acorn Woodpecker again, "))
        #expect(!FindRow.seenAgainLine(seen).contains(", ,"))
        #expect(FindRow.spoken(item).contains("Heard again by Maya Ortiz"))
        #expect(!FindRow.spoken(item).contains("New patch"))
        #expect(FindRow.marks(item) == ["First for the Guild"])
    }

    @Test("a repeat shared by hand keeps the patch-led row; an automatic repeat stays a quiet line")
    func ledWithoutANewPatch() {
        var shared = Self.item()
        shared.card = FeedItem.SharedCard(note: "By the gate.", caption: nil, photo: nil)
        #expect(FindRow.isLed(shared))
        #expect(FindRow.headline(shared) == "Maya shared a sighting")
        #expect(!FindRow.isLed(Self.item()), "nobody shared it, so it can't say they did")
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


// Issue #150: Guild screens draw what the store last had at once. The list, each Guild's detail and goals and each feed's
// first page outlive a launch in a small file, until sign-out or account deletion.
@Suite("Last-known Guilds on disk")
struct CircleCacheTests {
    private func file() -> URL {
        URL.temporaryDirectory.appending(path: "circle-cache-\(UUID().uuidString)/last-known.json")
    }

    /// A store over the seeded fake that has read Sunday Group's page, with its cache written.
    private func filled(at url: URL, client: FakeCircleClient = FakeCircleClient(seeded: true)) async throws -> (CircleStore, CircleSummary) {
        let cache = CircleCache(fileURL: url)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client, cache: cache)
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        try await store.loadDetail(id: sunday.id)
        await store.loadGoals(circleID: sunday.id)
        await store.loadFeed(circleID: sunday.id)
        // Past the store's own delayed write, then its last write on disk.
        try await Task.sleep(for: .milliseconds(300))
        store.writeCache()
        cache.finishWrites()
        return (store, sunday)
    }

    private func offlineStore(at url: URL, signedIn: Bool = true) -> CircleStore {
        CircleStore(account: FakeAccount.session(signedIn: signedIn), client: FakeCircleClient(seeded: false, offline: true), cache: CircleCache(fileURL: url))
    }

    @Test("the next launch draws the list, the Guild and its finds before any answer, and refreshing offline keeps them")
    func drawsAtOnce() async throws {
        let url = file()
        let (first, sunday) = try await filled(at: url)

        let next = offlineStore(at: url)
        #expect(next.circles == first.circles, "no answer asked for yet")
        #expect(next.listState == .loaded)
        #expect(next.details[sunday.id] == first.details[sunday.id])
        let feed = try #require(next.feeds[sunday.id])
        #expect(feed.isLoaded)
        #expect(feed.items.map(\.id) == first.feeds[sunday.id]?.items.map(\.id))
        #expect(feed.items.map(\.commonName) == first.feeds[sunday.id]?.items.map(\.commonName))
        #expect(feed.items.map(\.reactions) == first.feeds[sunday.id]?.items.map(\.reactions))
        #expect(feed.items.map(\.newPatch) == first.feeds[sunday.id]?.items.map(\.newPatch))
        #expect(feed.items.map(\.place) == first.feeds[sunday.id]?.items.map(\.place), "a secret spot stays one")
        #expect(next.goals[sunday.id]?.map(\.title) == first.goals[sunday.id]?.map(\.title))

        await next.refresh()
        await next.loadFeed(circleID: sunday.id)
        #expect(next.circles == first.circles, "offline keeps what's drawn")
        #expect(next.feeds[sunday.id]?.items.count == feed.items.count)
    }

    @Test("what's drawn from the cache is still read again, in place")
    func refreshesInPlace() async throws {
        let url = file()
        let (_, sunday) = try await filled(at: url)
        let next = CircleStore(account: FakeAccount.session(signedIn: true), client: FakeCircleClient(seeded: true), cache: CircleCache(fileURL: url))
        #expect(next.needsDetail(sunday.id))
        #expect(next.needsGoals(sunday.id))
        try await next.loadDetail(id: sunday.id)
        await next.loadGoals(circleID: sunday.id)
        #expect(!next.needsDetail(sunday.id))
        #expect(!next.needsGoals(sunday.id))
    }

    @Test("only the first page of a feed is kept")
    func firstPageOnly() async throws {
        let url = file()
        let client = FakeCircleClient(seeded: false)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client, cache: CircleCache(fileURL: url))
        let circle = try await store.create(named: "Big Day")
        for minute in 0..<25 {
            var input = FindPolicyTests.input()
            input.confirmedAt = FindPolicyTests.confirmedAt.addingTimeInterval(Double(minute) * 60)
            try await client.putFind(FindPolicy.find(for: input, sharing: .automatic)!, sightingID: UUID(), accessToken: "t")
        }
        await store.loadFeed(circleID: circle.circle.id)
        let firstCursor = store.feeds[circle.circle.id]?.nextCursor
        await store.loadMoreFeed(circleID: circle.circle.id)
        #expect(store.feeds[circle.circle.id]?.items.count == 25)
        let kept = try #require(store.snapshot.feeds[circle.circle.id])
        #expect(kept.items.count == 20)
        #expect(kept.nextCursor == firstCursor)
    }

    @Test("sign-out removes it, and an answer on its way then doesn't bring it back")
    func removedOnClear() async throws {
        let url = file()
        let client = FakeCircleClient(seeded: true)
        let (store, sunday) = try await filled(at: url, client: client)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        client.latency = .milliseconds(100)
        async let late: Void = store.loadFeed(circleID: sunday.id)
        try await Task.sleep(for: .milliseconds(10))
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        await late
        try await Task.sleep(for: .milliseconds(350))
        #expect(store.feeds.isEmpty, "the late answer is dropped")
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("a cache found while signed out goes without being read")
    func signedOutAtLaunch() async throws {
        let url = file()
        _ = try await filled(at: url)
        let store = offlineStore(at: url, signedIn: false)
        #expect(store.circles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("a file it can't read is no cache at all")
    func unreadable() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = offlineStore(at: url)
        #expect(store.circles.isEmpty)
        #expect(store.listState == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("a Guild left, and a blocked friend's finds, leave what's kept")
    func leavesWithThem() async throws {
        let url = file()
        let (store, sunday) = try await filled(at: url)
        let friend = try #require(store.feeds[sunday.id]?.items.first { !$0.isMine }?.owner)
        try await store.setBlocked(true, accountID: friend.id, name: friend.displayName)
        #expect(store.snapshot.feeds[sunday.id]?.items.contains { $0.owner.id == friend.id } == false)

        let family = try #require(store.circles.first { $0.name == "Family" })
        try await store.leave(circleID: family.id)
        #expect(!store.snapshot.circles.contains { $0.id == family.id })
        #expect(store.snapshot.feeds[family.id] == nil)
    }

    @Test("a page on its way when a friend is blocked doesn't bring their finds back")
    func aPageOnItsWay() async throws {
        let url = file()
        let client = FakeCircleClient(seeded: true)
        let (store, sunday) = try await filled(at: url, client: client)
        let friend = try #require(store.feeds[sunday.id]?.items.first { !$0.isMine }?.owner)
        let shownBefore = store.feeds[sunday.id]?.items.count ?? 0
        client.latency = .milliseconds(200)
        async let late: Void = store.loadFeed(circleID: sunday.id)
        try await Task.sleep(for: .milliseconds(20))
        try await store.setBlocked(true, accountID: friend.id, name: friend.displayName)
        await late
        let items = try #require(store.feeds[sunday.id]?.items)
        #expect(!items.contains { $0.owner.id == friend.id })
        #expect(items.count < shownBefore)
        #expect(store.snapshot.feeds[sunday.id]?.items.count == items.count, "the first page's count stays true")
    }

    @Test("a Guild the birder is no longer in isn't kept, though the store read it")
    func goneFromTheList() async throws {
        let url = file()
        let client = FakeCircleClient(seeded: true)
        let (store, sunday) = try await filled(at: url, client: client)
        try await client.leave(circleID: sunday.id, accessToken: "t")
        await store.refresh()
        #expect(store.snapshot.feeds[sunday.id] == nil)
        #expect(store.snapshot.details[sunday.id] == nil)
        #expect(store.snapshot.goals[sunday.id] == nil)
    }

    @Test("a block made on another device takes the friend's finds out of what was restored, and off the disk")
    func blockedElsewhere() async throws {
        let url = file()
        let client = FakeCircleClient(seeded: true)
        let (first, sunday) = try await filled(at: url, client: client)
        let friend = try #require(first.feeds[sunday.id]?.items.first { !$0.isMine }?.owner)

        let elsewhere = CircleCache(fileURL: url)
        let next = CircleStore(account: FakeAccount.session(signedIn: true), client: client, cache: elsewhere)
        #expect(next.feeds[sunday.id]?.items.contains { $0.owner.id == friend.id } == true, "restored as it was")
        try await client.setBlocked(true, accountID: friend.id, accessToken: "t")
        await next.refresh()
        #expect(next.feeds[sunday.id]?.items.contains { $0.owner.id == friend.id } == false)
        next.writeCache()
        elsewhere.finishWrites()
        let again = CircleStore(account: FakeAccount.session(signedIn: true), client: client, cache: CircleCache(fileURL: url))
        #expect(again.feeds[sunday.id]?.items.isEmpty == false)
        #expect(again.feeds[sunday.id]?.items.contains { $0.owner.id == friend.id } == false, "nor on disk")
    }

    @Test("blocking a friend drops what was last read of their birds")
    func blockDropsCompare() async throws {
        let client = FakeCircleClient(seeded: true)
        let (store, _) = try await filled(at: file(), client: client)
        try await store.compare(friendID: "maya")
        #expect(store.friendBirds["maya"] != nil)
        try await store.setBlocked(true, accountID: "maya", name: "Maya Ortiz")
        #expect(store.friendBirds["maya"] == nil)
    }

    @Test("Compare answering not found drops what was last read, as for a block made elsewhere")
    func notFoundDropsCompare() async throws {
        let client = FakeCircleClient(seeded: true)
        let (store, _) = try await filled(at: file(), client: client)
        try await store.compare(friendID: "maya")
        try await client.setBlocked(true, accountID: "maya", accessToken: "t")
        await #expect(throws: CircleError.notFound) { try await store.compare(friendID: "maya") }
        #expect(store.friendBirds["maya"] == nil)
    }

    @Test("a block out of date here, lifted on another device, doesn't strand Compare: the server's answer is kept")
    func staleBlockKeepsTheAnswer() async throws {
        let client = FakeCircleClient(seeded: true)
        let (store, _) = try await filled(at: file(), client: client)
        try await store.setBlocked(true, accountID: "maya", name: "Maya Ortiz")
        try await client.setBlocked(false, accountID: "maya", accessToken: "t")
        #expect(store.blocked.contains { $0.id == "maya" }, "still listed here")

        let birds = try await store.compare(friendID: "maya")
        #expect(!birds.species.isEmpty)
        #expect(store.friendBirds["maya"] == birds, "there for the screen to draw")
    }

    @Test("a block landing while Compare's answer is on its way drops the answer, and says so")
    func blockMidCallDropsTheAnswer() async throws {
        let client = FakeCircleClient(seeded: true)
        let (store, _) = try await filled(at: file(), client: client)
        client.compareAnswerLatency = .milliseconds(300)
        let answer = Task { try await store.compare(friendID: "maya") }
        try await Task.sleep(for: .milliseconds(50))
        try await store.setBlocked(true, accountID: "maya", name: "Maya Ortiz")
        await #expect(throws: CircleError.notFound) { try await answer.value }
        #expect(store.friendBirds["maya"] == nil)
    }

    @Test("a friend's side of Compare is there the next time it's opened")
    func compareIsKept() async throws {
        let (store, _) = try await filled(at: file())
        let birds = try await store.compare(friendID: "maya")
        #expect(store.friendBirds["maya"] == birds)
        store.clear()
        #expect(store.friendBirds.isEmpty)
    }
}

// Issue #150, G3 and G4: the Guilds tab's merged feed, and a feed's rows.
@Suite("Friends around the app")
@MainActor
struct FriendsAroundTheAppTests {
    /// Over the seeded fake, where Pat shares Sunday Group with Maya, Jo and Sam, and Family with Robin and Lee.
    private func seeded() -> (CircleStore, FakeCircleClient) {
        let client = FakeCircleClient(seeded: true)
        return (CircleStore(account: FakeAccount.session(signedIn: true), client: client), client)
    }

    @Test("each friend's species are read once, whoever asks and however often")
    func once() async {
        let (store, client) = seeded()
        await store.loadFriendsBirds()
        let friends = ["dad", "jo", "lee", "maya", "sam"]
        #expect(client.compareLog.sorted() == friends)
        await store.loadFriendsBirds()
        await store.loadFriendsBirds()
        #expect(client.compareLog.sorted() == friends, "at most once a session per friend")
    }

    @Test("two screens asking at once read each friend once")
    func overlapping() async {
        let (store, client) = seeded()
        client.latency = .milliseconds(5)
        async let first: Void = store.loadFriendsBirds()
        async let second: Void = store.loadFriendsBirds()
        _ = await (first, second)
        #expect(client.compareLog.count == 5)
    }

    @Test("a screen that has read Compare has read that friend")
    func compareCounts() async throws {
        let (store, client) = seeded()
        try await store.compare(friendID: "maya")
        await store.loadFriendsBirds()
        #expect(client.compareLog.filter { $0 == "maya" }.count == 1)
    }

    @Test("nothing is read until a screen asks, and nothing for someone signed out")
    func lazily() async {
        let (store, client) = seeded()
        await store.refresh()
        await store.loadRunningGoals()
        #expect(client.compareLog.isEmpty, "not at launch, nor for Listen")
        let signedOut = FakeCircleClient(seeded: true)
        let out = CircleStore(account: FakeAccount.session(signedIn: false), client: signedOut)
        await out.loadFriendsBirds()
        #expect(signedOut.compareLog.isEmpty)
    }

    @Test("it knows who has which bird, and never the birder")
    func who() async {
        let (store, _) = seeded()
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Sayornis nigricans").map(\.id) == ["jo", "maya"], "by name")
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.name) == ["Maya Ortiz"])
        #expect(store.friends(having: "Turdus merula").isEmpty)
        #expect(!store.friendsBySpecies.values.joined().contains { $0.id == FakeCircleClient.me })
    }

    @Test("sign-out clears it, an answer on its way stays out, and the next session reads again")
    func signOut() async throws {
        let (store, client) = seeded()
        await store.loadFriendsBirds()
        #expect(!store.friendsBySpecies.isEmpty)
        store.clear()
        #expect(store.friendsBySpecies.isEmpty)
        #expect(store.friendBirds.isEmpty)

        client.latency = .milliseconds(100)
        let late = Task { await store.loadFriendsBirds() }
        try await Task.sleep(for: .milliseconds(150))
        store.clear()
        await late.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.friendBirds.isEmpty, "the late answer is dropped")
        #expect(store.friendsBySpecies.isEmpty)
        client.latency = .zero

        let before = client.compareLog.count
        await store.loadFriendsBirds()
        #expect(client.compareLog.count > before)
    }

    @Test("someone blocked is out at once, isn't read, and can be read again once unblocked")
    func blocked() async throws {
        let (store, client) = seeded()
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.id) == ["maya"])
        try await store.setBlocked(true, accountID: "maya", name: "Maya Ortiz")
        #expect(store.friends(having: "Melanerpes formicivorus").isEmpty)
        #expect(store.friends(having: "Sayornis nigricans").map(\.id) == ["jo"])

        let reads = client.compareLog.count
        await store.loadFriendsBirds()
        #expect(client.compareLog.count == reads)

        try await store.setBlocked(false, accountID: "maya", name: "Maya Ortiz")
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.id) == ["maya"])
    }

    @Test("someone already blocked at the start is never asked for")
    func blockedBefore() async throws {
        let client = FakeCircleClient(seeded: true)
        try await client.setBlocked(true, accountID: "maya", accessToken: "t")
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.loadFriendsBirds()
        #expect(!client.compareLog.contains("maya"))
        #expect(store.friends(having: "Melanerpes formicivorus").isEmpty)
    }

    @Test("a block made elsewhere comes back as not found: they go, and aren't asked again")
    func notFound() async throws {
        let (store, client) = seeded()
        await store.loadFriendsBirds()
        try await client.setBlocked(true, accountID: "jo", accessToken: "t")
        await #expect(throws: CircleError.notFound) { try await store.compare(friendID: "jo") }
        #expect(store.friends(having: "Calypte anna").isEmpty)
        let reads = client.compareLog.count
        await store.loadFriendsBirds()
        #expect(client.compareLog.count == reads)
    }

    @Test("leaving the only Guild shared with someone takes their face away")
    func left() async throws {
        let (store, _) = seeded()
        await store.loadFriendsBirds()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        try await store.leave(circleID: sunday.id)
        #expect(store.friends(having: "Melanerpes formicivorus").isEmpty)
    }

    @Test("no connection from the start costs one call, not one per Guild or friend")
    func offlineFromTheStart() async {
        let (store, client) = seeded()
        client.isOffline = true
        await store.loadFriendsBirds()
        #expect(client.compareLog.isEmpty, "it never got as far as a friend")
        client.isOffline = false
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.id) == ["maya"])
    }

    @Test("the screen that asked going away doesn't stop the read: the next screen is waiting on it")
    func cancelled() async {
        let (store, client) = seeded()
        client.latency = .milliseconds(20)
        let first = Task { await store.loadFriendsBirds() }
        try? await Task.sleep(for: .milliseconds(30))
        first.cancel()
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.id) == ["maya"])
        #expect(client.compareLog.count == 5, "each once")
    }

    @Test("no connection stops at the first failure, and the next screen tries again")
    func offline() async {
        let (store, client) = seeded()
        await store.refresh()
        for circle in store.circles { try? await store.loadDetail(id: circle.id) }
        client.isOffline = true
        await store.loadFriendsBirds()
        #expect(client.compareLog.count == 1, "one failure, not one per friend")
        client.isOffline = false
        await store.loadFriendsBirds()
        #expect(store.friends(having: "Melanerpes formicivorus").map(\.id) == ["maya"])
    }

    @Test("a friend's editions come from their finds, earliest found first, and none is none")
    func editions() async throws {
        let client = FakeCircleClient(seeded: true)
        client.seedSharedFinds()
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.refresh()
        let lee = try await store.compare(friendID: "lee")
        #expect(lee.species.first { $0.commonName == "Black Phoebe" }?.editions == ["us-ca-sd"])
        #expect(lee.species.first { $0.commonName == "House Finch" }?.editions == ["us-ca-la"])
    }
}

@Suite("A feed's rows")
struct FindFeedRowTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func item(_ sighting: String, owner: String = "maya", hoursAgo: Double = 0, newPatch: Bool = false, first: Bool = false, rarity: RarityLabel? = .common, card: Bool = false) -> FeedItem {
        FeedItem(
            sightingID: sighting, speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe", method: .heard, place: "Pasadena",
            foundAt: start.addingTimeInterval(-hoursAgo * 3600), newPatch: newPatch, rarity: rarity, art: nil,
            owner: .init(id: owner, displayName: owner), circleFirst: first, isMine: false,
            card: card ? .init(note: "Hello", caption: nil, photo: nil) : nil
        )
    }

    private static func rows(_ items: [FeedItem]) -> [[String]] {
        FindFeedRow.rows(of: items.map { FindEntry(item: $0, circleIDs: ["c"]) }).map { row in
            switch row {
            case .find(let entry): [entry.item.sightingID]
            case .repeats(let entries): entries.map(\.item.sightingID)
            }
        }
    }

    @Test("a member's consecutive repeats within a day gather into one line")
    func gathers() {
        #expect(Self.rows([Self.item("a", hoursAgo: 1), Self.item("b", hoursAgo: 2), Self.item("c", hoursAgo: 20)]) == [["a", "b", "c"]])
    }

    @Test("one repeat alone stays its own quiet row")
    func oneAlone() {
        #expect(Self.rows([Self.item("a")]) == [["a"]])
    }

    @Test("another member's repeat ends the run")
    func anotherMember() {
        #expect(Self.rows([Self.item("a", hoursAgo: 1), Self.item("b", owner: "jo", hoursAgo: 2), Self.item("c", hoursAgo: 3)]) == [["a"], ["b"], ["c"]])
    }

    @Test("a day is counted from the newest in the run")
    func aDay() {
        #expect(Self.rows([Self.item("a", hoursAgo: 0), Self.item("b", hoursAgo: 24), Self.item("c", hoursAgo: 25), Self.item("d", hoursAgo: 26)]) == [["a", "b"], ["c", "d"]])
    }

    @Test("a new patch, a shared card and any mark stand alone, and end the run")
    func standsAlone() {
        for find in [
            Self.item("m", hoursAgo: 2, newPatch: true),
            Self.item("m", hoursAgo: 2, card: true),
            Self.item("m", hoursAgo: 2, first: true),
            Self.item("m", hoursAgo: 2, rarity: .rare),
            Self.item("m", hoursAgo: 2, rarity: .exceptional),
        ] {
            let run = [Self.item("a", hoursAgo: 0), Self.item("b", hoursAgo: 1), find, Self.item("c", hoursAgo: 3), Self.item("d", hoursAgo: 4)]
            #expect(Self.rows(run) == [["a", "b"], ["m"], ["c", "d"]])
        }
    }

    @Test("an uncommon bird isn't a mark, so it gathers")
    func uncommonGathers() {
        #expect(Self.rows([Self.item("a", rarity: .uncommon), Self.item("b", hoursAgo: 1, rarity: nil)]) == [["a", "b"]])
    }

    @Test("two Guilds' copies of a find are one entry naming both, newest first")
    func merges() {
        let entries = FindEntry.merging([
            ("c1", [Self.item("a", hoursAgo: 1), Self.item("b", hoursAgo: 3)]),
            ("c2", [Self.item("c", hoursAgo: 2), Self.item("b", hoursAgo: 3)]),
        ])
        #expect(entries.map(\.item.sightingID) == ["a", "c", "b"])
        #expect(entries.map(\.circleIDs) == [["c1"], ["c2"], ["c1", "c2"]])
    }

    @Test("the same sighting number from two owners is two finds")
    func twoOwners() {
        let entries = FindEntry.merging([("c1", [Self.item("a")]), ("c2", [Self.item("a", owner: "jo")])])
        #expect(entries.count == 2)
    }

    @Test("an entry never says more of where the bird was than the copy that says least")
    func placeStaysHidden() {
        var hidden = Self.item("a")
        hidden.place = nil
        #expect(FindEntry.merging([("c1", [Self.item("a")]), ("c2", [hidden])]).first?.item.place == nil)
        #expect(FindEntry.merging([("c1", [hidden]), ("c2", [Self.item("a")])]).first?.item.place == nil)
        var secret = Self.item("a")
        secret.place = FindPolicy.secretSpot
        #expect(FindEntry.merging([("c1", [Self.item("a")]), ("c2", [secret])]).first?.item.place == FindPolicy.secretSpot)
        #expect(FindEntry.merging([("c1", [secret]), ("c2", [Self.item("a")])]).first?.item.place == FindPolicy.secretSpot)
    }

    @Test("an entry keeps a card and a mark from either copy")
    func keepsExtras() {
        let entry = FindEntry.merging([("c1", [Self.item("a")]), ("c2", [Self.item("a", first: true, card: true)])]).first
        #expect(entry?.item.circleFirst == true)
        #expect(entry?.item.card?.note == "Hello")
    }

    @Test("a CDN thumbnail shows only if it's the find's own edition's patch")
    func thumbnails() {
        let url = URL(string: "https://cdn.example.com/x.png")!
        var find = Self.item("a")
        find.edition = "us-ca-sd"
        find.art = .init(kind: "pack", key: "packs/us-ca-sd/patch/x.png", url: url)
        #expect(FindPatchPicture.thumbnail(of: find) == url)
        find.art = .init(kind: "pack", key: "packs/us-ca-la/patch/x.png", url: url)
        #expect(FindPatchPicture.thumbnail(of: find) == nil, "never another edition's")
        find.art = .init(kind: "pack", key: "packs/us-ca-sd/x.jpg", url: url)
        #expect(FindPatchPicture.thumbnail(of: find) == nil, "not a patch")
        find.edition = nil
        find.art = .init(kind: "pack", key: "packs/us-ca-sd/patch/x.png", url: url)
        #expect(FindPatchPicture.thumbnail(of: find) == nil)
    }

    @Test("a repeat's page says who met it again, the same way")
    func repeatHeadline() {
        var find = Self.item("a")
        #expect(FindRow.fullHeadline(find) == "maya heard this bird again")
        find.method = .seen
        #expect(FindRow.fullHeadline(find) == "maya saw this bird again")
    }

    @Test("the blocked are left out")
    func blocked() {
        let entries = FindEntry.merging([("c1", [Self.item("a"), Self.item("b", owner: "jo")])], blocked: ["maya"])
        #expect(entries.map(\.item.owner.id) == ["jo"])
    }
}

#if DEBUG
@Suite("The merged feed")
@MainActor
struct MergedFeedTests {
    private func store(seeded: Bool = true) -> (CircleStore, FakeCircleClient) {
        let client = FakeCircleClient(seeded: seeded)
        return (CircleStore(account: FakeAccount.session(signedIn: true), client: client), client)
    }

    private func put(_ client: FakeCircleClient, _ circleID: String, _ count: Int, owner: String, startingAt start: Date, every interval: TimeInterval) {
        for index in 0..<count {
            client.add(FeedItem(
                sightingID: "\(owner)-\(index)", speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
                method: .seen, place: nil, foundAt: start.addingTimeInterval(-Double(index) * interval), newPatch: true, rarity: .common, art: nil,
                owner: .init(id: owner, displayName: owner), circleFirst: false, isMine: false
            ), to: circleID)
        }
    }

    @Test("a find in two Guilds is one row naming both")
    func oneRow() async throws {
        let (store, client) = store()
        client.seedSharedFinds()
        await store.refresh()
        await store.loadMergedFeed()
        let feed = store.mergedFeed
        #expect(feed.isLoaded)
        let shared = try #require(feed.entries.first { $0.item.sightingID == "00000000-0000-4000-8000-000000000001" })
        let names = shared.circleIDs.compactMap { id in store.circles.first { $0.id == id }?.name }
        #expect(names == ["Sunday Group", "Family"])
        #expect(feed.entries.count == Set(feed.entries.map(\.id)).count)
    }

    @Test("the next page comes from whichever Guild's next item is newest, and nothing lands above what's already shown")
    func pages() async throws {
        let (store, client) = store(seeded: false)
        let busy = try await store.create(named: "Busy").circle.id
        let quiet = try await store.create(named: "Quiet").circle.id
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // Busy has 25 finds an hour apart. Quiet has 25 a day apart, so most of Quiet is older than all of Busy.
        put(client, busy, 25, owner: "busy", startingAt: now, every: 3600)
        put(client, quiet, 25, owner: "quiet", startingAt: now.addingTimeInterval(-1800), every: 86_400)
        await store.refresh()
        await store.loadMergedFeed()
        let times = { store.mergedFeed.entries.map(\.item.foundAt) }
        #expect(times() == times().sorted(by: >))
        // Busy's first page reaches back 19 hours, so a find of Busy's newer than most of Quiet's first page may still be unread:
        // it shows Busy's 20 and the one of Quiet's inside those hours.
        let shown = store.mergedFeed.entries.map(\.id)
        #expect(shown.count == 21)

        await store.loadMoreMergedFeed()
        #expect(store.feeds[busy]?.items.count == 25, "Busy's next find is the newest unread")
        #expect(store.feeds[quiet]?.items.count == 20)
        #expect(Array(store.mergedFeed.entries.map(\.id).prefix(shown.count)) == shown, "nothing lands above what's shown")

        await store.loadMoreMergedFeed()
        #expect(store.feeds[quiet]?.items.count == 25)
        #expect(!store.mergedFeed.hasMore)
        #expect(store.mergedFeed.entries.count == 50)
        #expect(times() == times().sorted(by: >))
    }

    @Test("a block made elsewhere takes a friend's finds out of the merged feed")
    func blocks() async throws {
        let (store, client) = store()
        client.seedSharedFinds()
        await store.refresh()
        await store.loadMergedFeed()
        #expect(store.mergedFeed.entries.contains { $0.item.owner.id == "jo" })
        // On another phone.
        try await client.setBlocked(true, accountID: "jo", accessToken: "t")
        await store.loadBlocks()
        #expect(!store.mergedFeed.entries.contains { $0.item.owner.id == "jo" })
        #expect(store.entry(id: "jo/00000000-0000-4000-8000-000000000001") == nil, "an open find's page has nothing to show")
    }

    @Test("a reaction reaches the merged row, and both Guilds' copies")
    func reaction() async throws {
        let (store, client) = store()
        client.seedSharedFinds()
        await store.refresh()
        await store.loadMergedFeed()
        let shared = try #require(store.mergedFeed.entries.first { $0.item.sightingID == "00000000-0000-4000-8000-000000000001" })
        try await store.react(.lovely, given: true, to: shared.item)
        #expect(store.entry(id: shared.id)?.item.reaction(.lovely).mine == true)
        for id in shared.circleIDs {
            #expect(store.feeds[id]?.items.first { $0.id == shared.id }?.reaction(.lovely).count == 1)
        }
    }

    @Test("a blocked friend leaves a Guild's faces and Compare, and stays in the list to unblock them from")
    func blockedMembers() async throws {
        let (store, client) = store()
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        try await store.loadDetail(id: sunday.id)
        try await client.setBlocked(true, accountID: "maya", accessToken: "t")
        await store.loadBlocks()
        let detail = try #require(store.details[sunday.id])
        #expect(detail.members.contains { $0.id == "maya" })
        #expect(!store.visibleMembers(of: detail).contains { $0.id == "maya" })
    }

    @Test("a feed is read again once it's a while old, unless the birder has gone further down")
    func staleness() async throws {
        let (store, client) = store(seeded: false)
        let busy = try await store.create(named: "Busy").circle.id
        let quiet = try await store.create(named: "Quiet").circle.id
        #expect(store.isFeedStale(busy), "not read yet")
        await store.loadMergedFeed()
        let soon = Date.now.addingTimeInterval(30)
        let later = Date.now.addingTimeInterval(120)
        #expect(!store.isFeedStale(busy, now: soon))
        #expect(store.isFeedStale(busy, now: later))
        put(client, busy, 25, owner: "busy", startingAt: .now, every: 60)
        await store.loadFeed(circleID: busy)
        await store.loadMoreFeed(circleID: busy)
        #expect(!store.isFeedStale(busy, now: later), "it would throw away the second page")
        #expect(!store.isFeedStale(quiet, now: later), "it could move the horizon of what's being read")
    }

    @Test("a report names the Guild the find was opened in")
    func reportingCircle() {
        let item = FeedItem(
            sightingID: "a", speciesID: "x_y", scientificName: "x", commonName: "y", method: .seen, place: nil, foundAt: .now, newPatch: true,
            rarity: nil, art: nil, owner: .init(id: "maya", displayName: nil), circleFirst: false, isMine: false
        )
        let entry = FindEntry(item: item, circleIDs: ["c1", "c2"])
        #expect(FindRoute(itemID: entry.id, surface: .guild("c2")).reportingCircle(of: entry) == "c2")
        #expect(FindRoute(itemID: entry.id, surface: .allGuilds).reportingCircle(of: entry) == "c1")
        #expect(FindRoute(itemID: entry.id, surface: .guild("elsewhere")).reportingCircle(of: entry) == "c1")
    }

    /// Two Guilds of 25 finds each, every page read: 50 rows.
    private func allRead() async throws -> (store: CircleStore, client: FakeCircleClient, busy: String, quiet: String) {
        let (store, client) = store(seeded: false)
        let busy = try await store.create(named: "Busy").circle.id
        let quiet = try await store.create(named: "Quiet").circle.id
        let now = Date.now
        put(client, busy, 25, owner: "busy", startingAt: now, every: 3600)
        put(client, quiet, 25, owner: "quiet", startingAt: now.addingTimeInterval(-1800), every: 3600)
        await store.refresh()
        await store.loadMergedFeed()
        while store.mergedFeed.hasMore { await store.loadMoreMergedFeed() }
        #expect(store.mergedFeed.entries.count == 50)
        return (store, client, busy, quiet)
    }

    @Test("a push keeps the pages already read, with what it brings on top")
    func pushKeepsPages() async throws {
        let (store, client, busy, _) = try await allRead()
        let before = store.mergedFeed.entries.map(\.id)
        let page2 = try #require(before.last)
        client.add(FeedItem(
            sightingID: "new", speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .seen, place: nil, foundAt: .now.addingTimeInterval(60), newPatch: true, rarity: .common, art: nil,
            owner: .init(id: "busy", displayName: "busy"), circleFirst: false, isMine: false
        ), to: busy)
        await store.refreshAfterPush(circleIDs: [busy])
        let after = store.mergedFeed.entries.map(\.id)
        #expect(after == ["busy/new"] + before, "nothing moved")
        #expect(store.entry(id: page2) != nil, "a find on the second page")
        #expect(store.feeds[busy]?.nextCursor == nil, "the feed was read to its end, and still is")
    }

    @Test("a push for a Guild part way down reads on from where it was")
    func pushKeepsTheCursor() async throws {
        let (store, client) = store(seeded: false)
        let circle = try await store.create(named: "Long").circle.id
        put(client, circle, 50, owner: "a", startingAt: .now, every: 3600)
        await store.refresh()
        await store.loadFeed(circleID: circle)
        await store.loadMoreFeed(circleID: circle)
        #expect(store.feeds[circle]?.items.count == 40)
        await store.refreshAfterPush(circleIDs: [circle])
        #expect(store.feeds[circle]?.items.count == 40)
        await store.loadMoreFeed(circleID: circle)
        let feed = try #require(store.feeds[circle])
        #expect(feed.items.count == 50)
        #expect(Set(feed.items.map(\.id)).count == 50)
        #expect(feed.items.map(\.foundAt) == feed.items.map(\.foundAt).sorted(by: >))
    }

    @Test("a push's refresh takes out a find removed from within the page it read")
    func pushRemoves() async throws {
        let (store, client) = store(seeded: false)
        let circle = try await store.create(named: "Long").circle.id
        put(client, circle, 30, owner: "a", startingAt: .now, every: 3600)
        await store.refresh()
        await store.loadFeed(circleID: circle)
        await store.loadMoreFeed(circleID: circle)
        try await client.deleteFriendFind("a/a-3", circleID: circle)
        await store.refreshAfterPush(circleIDs: [circle])
        let items = try #require(store.feeds[circle]?.items)
        #expect(!items.contains { $0.id == "a/a-3" })
        #expect(items.count == 29)
    }

    @Test("what's kept on disk after a push is still the first page, with the cursor after it")
    func pushCachesTheFirstPage() async throws {
        let (store, client) = store(seeded: false)
        let circle = try await store.create(named: "Long").circle.id
        put(client, circle, 30, owner: "a", startingAt: .now, every: 3600)
        await store.refresh()
        await store.loadFeed(circleID: circle)
        await store.loadMoreFeed(circleID: circle)
        await store.refreshAfterPush(circleIDs: [circle])
        let kept = try #require(store.snapshot.feeds[circle])
        #expect(kept.items.count == 20)
        #expect(kept.nextCursor == "20")
    }

    @Test("an open find's page keeps its find through a read that leaves it out, until a block, or its Guild goes")
    func heldFind() async throws {
        let (store, _, busy, _) = try await allRead()
        let id = "busy/busy-24"
        store.holdOpen(id: id)
        await store.loadFeed(circleID: busy)
        #expect(store.feeds[busy]?.items.contains { $0.id == id } == false, "only the first page now")
        #expect(store.entry(id: id)?.item.sightingID == "busy-24")
        // A reaction still shows on it.
        let held = try #require(store.entry(id: id))
        try await store.react(.lovely, given: true, to: held.item)
        #expect(store.entry(id: id)?.item.reaction(.lovely).mine == true)

        try await store.leave(circleID: busy)
        #expect(store.entry(id: id) == nil, "its Guild has gone")
    }

    @Test("a held find goes with a block")
    func heldFindBlocked() async throws {
        let (store, client, _, quiet) = try await allRead()
        let id = "quiet/quiet-24"
        store.holdOpen(id: id)
        await store.loadFeed(circleID: quiet)
        #expect(store.entry(id: id) != nil)
        client.addMember("quiet", to: quiet)
        try await store.setBlocked(true, accountID: "quiet", name: nil)
        #expect(store.entry(id: id) == nil)
    }

    @Test("a held find is forgotten at sign-out")
    func heldFindCleared() async throws {
        let (store, _, _, _) = try await allRead()
        let id = "busy/busy-24"
        store.holdOpen(id: id)
        store.clear()
        #expect(store.entry(id: id) == nil)
    }

    @Test("opened from a Guild, a find's page says what that Guild's copy says")
    func keepsToItsGuild() async throws {
        let (store, client) = store()
        client.seedSharedFinds()
        await store.refresh()
        await store.loadMergedFeed()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" }).id
        let family = try #require(store.circles.first { $0.name == "Family" }).id
        let item = FeedItem(
            sightingID: "two", speciesID: "Sayornis nigricans_Black Phoebe", scientificName: "Sayornis nigricans", commonName: "Black Phoebe",
            method: .seen, place: "Pasadena", foundAt: .now, newPatch: false, rarity: .common, art: nil,
            owner: .init(id: "jo", displayName: "Jo Park"), circleFirst: false, isMine: false
        )
        client.add(item, to: sunday)
        client.add(item, to: family)
        await store.loadMergedFeed()
        let id = "jo/two"
        for circle in [sunday, family] {
            #expect(store.entry(id: id, openedIn: circle)?.circleIDs == [circle])
            #expect(store.entry(id: id, openedIn: circle)?.item.circleFirst == store.feeds[circle]?.items.first { $0.id == id }?.circleFirst)
        }
        #expect(store.entry(id: id)?.circleIDs == [sunday, family])
    }

    @Test("one Guild failing keeps the other's rows, and says so")
    func oneGuildFails() async throws {
        let (store, client) = store(seeded: false)
        let good = try await store.create(named: "Good").circle.id
        let bad = try await store.create(named: "Bad").circle.id
        put(client, good, 5, owner: "good", startingAt: .now, every: 3600)
        client.failingFeeds = [bad]
        await store.refresh()
        await store.loadMergedFeed()
        let feed = store.mergedFeed
        #expect(feed.entries.count == 5)
        #expect(feed.entries.allSatisfy { $0.circleIDs == [good] })
        #expect(feed.error?.contains("load the finds") == true)
        #expect(!feed.isLoaded, "one Guild hasn't come back")

        // And a Guild already read keeps its rows when its refresh fails.
        client.failingFeeds = [good]
        await store.refreshAfterPush(circleIDs: [good])
        #expect(store.mergedFeed.entries.count == 5)
        #expect(store.feeds[good]?.error != nil)
    }

    @Test("Lee's repeats gather, in the seeds the UI tests use")
    func seededRepeats() async throws {
        let (store, client) = store()
        client.seedSharedFinds()
        await store.refresh()
        await store.loadMergedFeed()
        let rows = FindFeedRow.rows(of: store.mergedFeed.entries)
        guard case .repeats(let line) = rows.first else {
            Issue.record("the newest row is Lee's line: \(rows.first?.id ?? "")")
            return
        }
        #expect(line.map(\.item.commonName) == ["House Finch", "Mourning Dove", "House Finch"])
    }

    @Test("the merged feed outlives a launch through the cache, and goes on sign-out")
    func cache() async throws {
        let url = URL.temporaryDirectory.appending(path: "merged-\(UUID().uuidString)/last-known.json")
        let client = FakeCircleClient(seeded: true)
        client.seedSharedFinds()
        let cache = CircleCache(fileURL: url)
        let first = CircleStore(account: FakeAccount.session(signedIn: true), client: client, cache: cache)
        await first.refresh()
        await first.loadMergedFeed()
        first.writeCache()
        cache.finishWrites()
        let next = CircleStore(account: FakeAccount.session(signedIn: true), client: FakeCircleClient(seeded: false, offline: true), cache: CircleCache(fileURL: url))
        #expect(next.mergedFeed.entries.map(\.id) == first.mergedFeed.entries.map(\.id))
        #expect(next.mergedFeed.isLoaded)
        next.clear()
        #expect(next.mergedFeed.entries.isEmpty)
    }
}
#endif
