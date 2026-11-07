import Album
import Foundation
import Testing
@testable import BirdJournal

// Issue #64: reactions and Compare birds over HTTP, the feed's counts, the store's reacting, the reaction push, and
// the comparison of the phone's collection with a friend's.

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

private let counts = #"{"reactions":[{"kind":"lovely","count":2,"mine":true},{"kind":"jealous","count":0,"mine":false},{"kind":"together","count":1,"mine":false}]}"#

@Suite("Reactions and Compare birds over HTTP")
struct ReactionClientTests {
    @Test("a reaction is put and deleted on the owner's find, and the counts come back")
    func putAndDelete() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, counts), http(200, counts)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let given = try await client.setReaction(.lovely, given: true, owner: "maya", sightingID: "s-1", accessToken: "t")
        _ = try await client.setReaction(.together, given: false, owner: "maya", sightingID: "s-1", accessToken: "t")
        #expect(recorder.requests.map { "\($0.httpMethod!) \($0.url!.path())" } == [
            "PUT /v1/finds/maya/s-1/reactions/lovely",
            "DELETE /v1/finds/maya/s-1/reactions/together",
        ])
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(recorder.requests[0].httpBody == nil, "no comment, no body")
        #expect(given.map(\.kind) == [.lovely, .jealous, .together])
        #expect(given.map(\.count) == [2, 0, 1])
        #expect(given.map(\.mine) == [true, false, false])
    }

    @Test("a feed item decodes its counts, and one from before reactions counts nothing")
    func feedCounts() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = """
        "sighting_id":"s","species_id":"Sayornis nigricans_Black Phoebe","scientific_name":"Sayornis nigricans",
        "common_name":"Black Phoebe","method":"heard","found_at":"2026-11-01T08:15:00Z","new_patch":false,
        "owner":{"id":"maya","display_name":"Maya Ortiz"},"circle_first":false,"is_mine":false
        """
        let with = try decoder.decode(FeedItem.self, from: Data(#"{\#(base),"reactions":[{"kind":"jealous","count":3,"mine":true},{"kind":"wave","count":9,"mine":false}]}"#.utf8))
        #expect(with.reactions == [
            ReactionCount(kind: .lovely, count: 0, mine: false),
            ReactionCount(kind: .jealous, count: 3, mine: true),
            ReactionCount(kind: .together, count: 0, mine: false),
        ], "every known kind in order; an unknown one is left out")
        let without = try decoder.decode(FeedItem.self, from: Data("{\(base)}".utf8))
        #expect(without.reactions == ReactionCount.none)
    }

    @Test("compare reads the editions a friend found each species in, earliest first")
    func compareEditions() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"friend":{"id":"maya","display_name":"Maya Ortiz"},"species":[{"species_id":"s","scientific_name":"Sayornis nigricans","common_name":"Black Phoebe","method":"seen","editions":["us-ca-sd","us-ca-la"]},{"species_id":"t","scientific_name":"Turdus merula","common_name":"Common Blackbird","method":"heard","editions":[]}]}"#)]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let friend = try await client.compare(friendID: "maya", accessToken: "t")
        #expect(friend.species.map(\.editions) == [["us-ca-sd", "us-ca-la"], []])
    }

    @Test("compare reads the friend's species")
    func compare() async throws {
        let recorder = Recorder()
        recorder.responses = [http(200, #"{"friend":{"id":"maya","display_name":"Maya Ortiz"},"species":[{"species_id":"Sayornis nigricans_Black Phoebe","scientific_name":"Sayornis nigricans","common_name":"Black Phoebe","method":"seen"}]}"#), http(404, "{}")]
        let client = HTTPCircleClient(baseURL: api, transport: recorder.transport)
        let friend = try await client.compare(friendID: "maya", accessToken: "t")
        #expect(recorder.requests[0].url?.path() == "/v1/friends/maya/compare")
        #expect(friend.friend.name == "Maya Ortiz")
        #expect(friend.species.map(\.method) == [.seen])
        #expect(friend.species.first?.editions == [], "an older server says nothing of editions")
        await #expect(throws: CircleError.notFound) { try await client.compare(friendID: "zed", accessToken: "t") }
    }
}

@Suite("A find's reactions")
struct ReactionCountTests {
    @Test("giving one adds the birder's, taking it back removes it, and repeating changes nothing")
    func reacting() {
        let item = FindRowTests.item()
        let given = item.reacting(.lovely, given: true)
        #expect(given.reaction(.lovely) == ReactionCount(kind: .lovely, count: 1, mine: true))
        #expect(given.reacting(.lovely, given: true) == given)
        #expect(given.reacting(.lovely, given: false).reaction(.lovely) == ReactionCount(kind: .lovely, count: 0, mine: false))
    }

    @Test("the birder's own find says what friends gave")
    func summary() {
        #expect(ReactionBar.summary([ReactionCount(kind: .lovely, count: 2, mine: false), ReactionCount(kind: .together, count: 1, mine: false)])
                == "Lovely find 2, Let's go together 1")
    }

    @Test("the fixed set, in order, with no comments")
    func kinds() {
        #expect(ReactionKind.allCases.map(\.title) == ["Lovely find", "Jealous!", "Let's go together"])
    }

    @Test("a reaction push names the find's circles, whose feeds show the new counts")
    func push() {
        let message = PushMessage(userInfo: ["aps": ["alert": ["title": "Maya reacted to your Black Phoebe"]], "kind": "reaction", "sighting_id": "s-1", "circle_ids": ["c1"]])
        #expect(message == .reaction(sightingID: "s-1", circleIDs: ["c1"]))
        #expect(message?.circleIDs == ["c1"])
        #expect(PushMessage(userInfo: ["kind": "reaction"]) == nil)
    }
}

@Suite("Compare birds")
struct BirdComparisonTests {
    private func species(_ label: String, _ method: SightingMethod) -> FriendBirds.Species {
        let common = BirdComparison.commonName(ofLabel: label)
        return .init(speciesID: label, scientificName: Sighting.scientificName(ofLabel: label), commonName: common, method: method)
    }

    @Test("each species is Heard, Seen or not yet on each side, and Seen beats Heard")
    func sides() {
        let comparison = BirdComparison(
            mine: [
                ("Sayornis nigricans_Black Phoebe", .heard),
                ("Sayornis nigricans_Black Phoebe", .seen),
                ("Sayornis nigricans_Black Phoebe", .heard),
                ("Calypte anna_Anna's Hummingbird", .heard),
            ],
            theirs: [
                species("Sayornis nigricans_Black Phoebe", .heard),
                species("Melanerpes formicivorus_Acorn Woodpecker", .heard),
                species("Melanerpes formicivorus_Acorn Woodpecker", .seen),
            ]
        )
        #expect(comparison.onlyTheirs.map(\.commonName) == ["Acorn Woodpecker"])
        #expect(comparison.onlyTheirs.first?.theirs == .seen)
        #expect(comparison.onlyTheirs.first?.mine == nil)
        #expect(comparison.onlyMine.map(\.commonName) == ["Anna's Hummingbird"])
        #expect(comparison.both.map { [$0.mine, $0.theirs] } == [[.seen, .heard]])
        #expect((comparison.myCount, comparison.theirCount) == (2, 2))
        #expect(BirdComparison.word(nil) == "Not yet")
        #expect(BirdComparison.word(.seen) == "Seen")
    }

    @Test("the boards: theirs you don't have yet, what you both have, only yours, each with the patch it shows")
    func boards() throws {
        let griffith = Coordinate(latitude: 0.5, longitude: 0.5, accuracy: 10)
        let elsewhere = Coordinate(latitude: 40, longitude: 40, accuracy: 10)
        let square = [[[CardSet.Point(longitude: 0, latitude: 0), CardSet.Point(longitude: 1, latitude: 0), CardSet.Point(longitude: 1, latitude: 1), CardSet.Point(longitude: 0, latitude: 1), CardSet.Point(longitude: 0, latitude: 0)]]]
        let losAngeles = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus", species: ["Sayornis nigricans", "Zenaida macroura"], regions: [CardSet.Region(name: "la", polygons: square)])
        let entry = { (label: String, at: TimeInterval, place: Coordinate) in
            CardCollection.Entry(identifier: UUID(), speciesID: label, confirmedAt: Date(timeIntervalSince1970: at), location: place)
        }
        let collection = CardCollection(
            [
                entry("Sayornis nigricans_Black Phoebe", 200, griffith),
                entry("Calypte anna_Anna's Hummingbird", 100, elsewhere),
                // Sewn in Los Angeles first, then Uncharted: the first patch is the one shown.
                entry("Zenaida macroura_Mourning Dove", 100, griffith),
                entry("Zenaida macroura_Mourning Dove", 900, elsewhere),
            ],
            sets: [losAngeles]
        )
        let comparison = BirdComparison(
            mine: [("Sayornis nigricans_Black Phoebe", .seen), ("Calypte anna_Anna's Hummingbird", .heard), ("Zenaida macroura_Mourning Dove", .heard)],
            theirs: [
                .init(speciesID: "a", scientificName: "Melanerpes formicivorus", commonName: "Acorn Woodpecker", method: .heard, editions: ["us-ca-sd", "us-ca-la"]),
                .init(speciesID: "b", scientificName: "Sayornis nigricans", commonName: "Black Phoebe", method: .heard, editions: ["us-ca-la"]),
                .init(speciesID: "c", scientificName: "Sialia mexicana", commonName: "Western Bluebird", method: .seen, editions: []),
                .init(speciesID: "d", scientificName: "Ardea alba", commonName: "Great Egret", method: .seen, editions: ["made-up"]),
            ],
            myPatches: collection.patches
        )
        let woodpecker = try #require(comparison.onlyTheirs.first { $0.commonName == "Acorn Woodpecker" })
        #expect(woodpecker.edition == "us-ca-sd", "the edition they first found it in, not any other")
        #expect(comparison.onlyTheirs.first { $0.commonName == "Western Bluebird" }?.edition == nil, "no edition from the server: the blank with its tag")
        #expect(comparison.onlyTheirs.first { $0.commonName == "Great Egret" }?.edition == "made-up", "PatchEdition draws an unknown set as a plain blank")
        #expect(comparison.both.map(\.edition) == ["us-ca-la"], "what you both have shows the friend's")
        #expect(comparison.onlyMine.map(\.commonName) == ["Anna's Hummingbird", "Mourning Dove"])
        #expect(comparison.onlyMine.map(\.edition) == [nil, "us-ca-la"], "your own, the earliest sewn, or Uncharted's blank")
        // Where each goes.
        #expect(woodpecker.route == .species(scientificName: "Melanerpes formicivorus", commonName: "Acorn Woodpecker"))
        #expect(comparison.both.first?.route == .species(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"))
        let onlyMine = try #require(comparison.onlyMine.last)
        #expect(onlyMine.myPatch == CardCollection.Patch.Key(speciesID: "Zenaida macroura_Mourning Dove", setID: "us-ca-la"))
        #expect(onlyMine.route == .patch(try #require(onlyMine.myPatch), from: .compare))
    }

    @Test("names come from the packs, then your own sightings, and only then the words of the friend's phone")
    func names() {
        let theirs: [FriendBirds.Species] = [
            .init(speciesID: "x", scientificName: "Sayornis nigricans", commonName: "Buy my thing", method: .seen),
            .init(speciesID: "y", scientificName: "Calypte anna", commonName: "Rude words", method: .seen),
            .init(speciesID: "z", scientificName: "Turdus merula", commonName: "Common Blackbird", method: .seen),
        ]
        let comparison = BirdComparison(
            mine: [("Calypte anna_Anna's Hummingbird", .heard)], theirs: theirs,
            names: ["Sayornis nigricans": "Black Phoebe"]
        )
        #expect(comparison.onlyTheirs.map(\.commonName) == ["Black Phoebe", "Common Blackbird"], "sorted by what's shown")
        #expect(comparison.both.map(\.commonName) == ["Anna's Hummingbird"])
    }

    @Test("Heard or Seen stays under every patch, and the tally stays")
    func words() {
        let comparison = BirdComparison(
            mine: [("Sayornis nigricans_Black Phoebe", .seen), ("Calypte anna_Anna's Hummingbird", .heard), ("Zenaida macroura_Mourning Dove", .heard)],
            theirs: [species("Sayornis nigricans_Black Phoebe", .seen), species("Calypte anna_Anna's Hummingbird", .seen), species("Ardea alba_Great Egret", .heard)]
        )
        let captions = (comparison.onlyTheirs + comparison.both + comparison.onlyMine).map { BirdComparison.caption($0, friend: "Maya") }
        #expect(captions == ["Heard by Maya", "Heard by you, seen by Maya", "Seen by you both", "Heard by you"])
        #expect(comparison.tally(friend: "Maya") == "You have 3, Maya has 3, and you both have 2.")
        #expect(BirdComparison.leadTitle(friend: "Maya") == "Maya has these. Go find them.")
    }

    @Test("nobody's birds compare to nothing")
    func empty() {
        let comparison = BirdComparison(mine: [], theirs: [])
        #expect(comparison.onlyTheirs.isEmpty && comparison.onlyMine.isEmpty && comparison.both.isEmpty)
    }
}

#if DEBUG
@Suite("Reacting in the circle feed")
@MainActor
struct ReactionStoreTests {
    private func sunday() async throws -> (CircleStore, FakeCircleClient, String) {
        let client = FakeCircleClient(seeded: true)
        let store = CircleStore(account: FakeAccount.session(signedIn: true), client: client)
        await store.refresh()
        let sunday = try #require(store.circles.first { $0.name == "Sunday Group" })
        await store.loadFeed(circleID: sunday.id)
        return (store, client, sunday.id)
    }

    @Test("a friend's find takes the birder's reaction and shows the new count; tapping again takes it back")
    func react() async throws {
        let (store, client, circle) = try await sunday()
        let phoebe = try #require(store.feeds[circle]?.items.first { $0.owner.id == "maya" && $0.commonName == "Black Phoebe" })
        #expect(phoebe.reaction(.lovely) == ReactionCount(kind: .lovely, count: 2, mine: false), "Jo and Sam's, seeded")
        try await store.react(.lovely, given: true, to: phoebe)
        #expect(store.feeds[circle]?.items.first { $0.id == phoebe.id }?.reaction(.lovely) == ReactionCount(kind: .lovely, count: 3, mine: true))
        let given = try #require(store.feeds[circle]?.items.first { $0.id == phoebe.id })
        try await store.react(.lovely, given: false, to: given)
        #expect(store.feeds[circle]?.items.first { $0.id == phoebe.id }?.reaction(.lovely).count == 2)
        #expect(client.reactionLog == ["put lovely \(phoebe.id)", "delete lovely \(phoebe.id)"])
        // The server agrees after a reload.
        await store.loadFeed(circleID: circle)
        #expect(store.feeds[circle]?.items.first { $0.id == phoebe.id }?.reaction(.lovely) == ReactionCount(kind: .lovely, count: 2, mine: false))
    }

    @Test("a refused reaction puts the find back as it was")
    func refused() async throws {
        let (store, _, circle) = try await sunday()
        var gone = try #require(store.feeds[circle]?.items.first { !$0.isMine })
        gone.sightingID = "00000000-0000-4000-8000-0000000000ff"
        await #expect(throws: CircleError.notFound) { try await store.react(.jealous, given: true, to: gone) }
        #expect(store.feeds[circle]?.items.allSatisfy { $0.reaction(.jealous).mine == false } == true)
    }

    @Test("the birder's own finds take no reaction from them")
    func ownFind() async throws {
        let (store, client, circle) = try await sunday()
        try await client.putFind(try #require(FindPolicy.find(for: FindPolicyTests.input(), sharing: .automatic)), sightingID: FindPolicyTests.identifier, accessToken: "t")
        await store.loadFeed(circleID: circle)
        let mine = try #require(store.feeds[circle]?.items.first { $0.isMine })
        try await store.react(.lovely, given: true, to: mine)
        #expect(client.reactionLog.isEmpty)
    }

    @Test("a friend's side comes from their finds in circles the two share, Seen beating Heard")
    func compare() async throws {
        let (store, _, _) = try await sunday()
        let maya = try await store.compare(friendID: "maya")
        #expect(maya.friend.name == "Maya Ortiz")
        #expect(maya.species.map(\.commonName) == ["Acorn Woodpecker", "Black Phoebe", "House Finch"])
        #expect(maya.species.map(\.method) == [.heard, .seen, .seen])
        // Ari is only in Canyon Walkers, which Pat isn't in.
        await #expect(throws: CircleError.notFound) { try await store.compare(friendID: "ari") }
    }
}
#endif
