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
        #expect(FindRow.whereAndWhen(Self.item()).hasPrefix("Pasadena · "))
        #expect(FindRow.whereAndWhen(Self.item(place: FindPolicy.secretSpot)).hasPrefix("At a secret spot · "))
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
        #expect(FindRow.headline(item) == "Maya Ortiz sewed a new patch")
        #expect(FindRow.headline(Self.item(newPatch: true, mine: true)) == "You sewed a new patch")
        #expect(FindRow.howAndWhere(item).hasPrefix("Heard · Pasadena · "))
        #expect(FindRow.spoken(item).hasPrefix("Black Phoebe. Heard by Maya Ortiz. Pasadena · "))
        #expect(FindRow.spoken(item).hasSuffix(". New patch. First for the Guild"))
    }

    @Test("a repeat is a quieter line, keeping its marks")
    func seenAgain() {
        let item = Self.item(first: true)
        #expect(!FindRow.isLed(item))
        #expect(FindRow.seenAgainLine(item).hasPrefix("Maya Ortiz heard a Black Phoebe again · Pasadena · "))
        var seen = Self.item(mine: true, place: nil)
        seen.method = .seen
        seen.commonName = "Acorn Woodpecker"
        #expect(FindRow.seenAgainLine(seen).hasPrefix("You saw an Acorn Woodpecker again · "))
        #expect(!FindRow.seenAgainLine(seen).contains("· ·"))
        #expect(FindRow.spoken(item).contains("Heard again by Maya Ortiz"))
        #expect(!FindRow.spoken(item).contains("New patch"))
        #expect(FindRow.marks(item) == ["First for the Guild"])
    }

    @Test("a repeat shared by hand keeps the patch-led row; an automatic repeat stays a quiet line")
    func ledWithoutANewPatch() {
        var shared = Self.item()
        shared.card = FeedItem.SharedCard(note: "By the gate.", caption: nil, photo: nil)
        #expect(FindRow.isLed(shared))
        #expect(FindRow.headline(shared) == "Maya Ortiz shared a sighting")
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

    @Test("a friend's side of Compare is there the next time it's opened")
    func compareIsKept() async throws {
        let (store, _) = try await filled(at: file())
        let birds = try await store.compare(friendID: "maya")
        #expect(store.friendBirds["maya"] == birds)
        store.clear()
        #expect(store.friendBirds.isEmpty)
    }
}
