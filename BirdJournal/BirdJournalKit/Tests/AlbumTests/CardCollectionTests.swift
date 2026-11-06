import Foundation
import Testing
@testable import Album

// Issue #132 (of #131): a birder collects patches, one per species per placement (a set, or Uncharted). The first
// sighting of a species in a placement sews its patch; later sightings there add to its count. The collection is a
// pure reading of the sightings, so these tests build value snapshots and nothing is stored.
@Suite("Patch collection")
struct CardCollectionTests {
    static let finch = "Haemorhous mexicanus_House Finch"
    static let phoebe = "Sayornis nigricans_Black Phoebe"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let la = CardSetTests.griffithPark
    static let sd = CardSetTests.balboaPark
    static let sets = CardSetTests.sets

    static func card(_ species: String, minutes: Double, id: Int, at place: Coordinate? = nil) -> CardCollection.Entry {
        CardCollection.Entry(identifier: uuid(id), speciesID: species, confirmedAt: start.addingTimeInterval(minutes * 60), location: place)
    }

    /// A UUID whose string sorts by `n`, so tie-breaks read in the test.
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test("one patch per species per placement, counting its sightings, sewn by the earliest")
    func onePatchPerSpeciesPerPlacement() throws {
        let cards = [
            Self.card(Self.finch, minutes: 30, id: 1, at: Self.la),
            Self.card(Self.phoebe, minutes: 20, id: 2, at: Self.la),
            Self.card(Self.finch, minutes: 10, id: 3, at: Self.la),
            Self.card(Self.finch, minutes: 40, id: 4, at: Self.sd),
            Self.card(Self.finch, minutes: 50, id: 5, at: Self.la),
        ]
        let collection = CardCollection(cards.shuffled(), sets: Self.sets)

        #expect(collection.patches.count == 3)
        let finchLA = try #require(collection.patch(of: Self.uuid(1)))
        #expect(finchLA.count == 3)
        #expect(finchLA.sewn.identifier == Self.uuid(3), "the earliest surviving sighting sewed it")
        #expect(finchLA.latest.identifier == Self.uuid(5))
        #expect(finchLA.sightings.map(\.identifier) == [Self.uuid(5), Self.uuid(1), Self.uuid(3)], "newest first")
        #expect(finchLA.placement.setID == "us-ca-la")
        #expect(collection.patch(of: Self.uuid(3)) == finchLA, "every sighting finds its patch")
        #expect(collection.sewedItsPatch(Self.uuid(3)))
        #expect(!collection.sewedItsPatch(Self.uuid(1)))

        let finchSD = try #require(collection.patch(of: Self.uuid(4)))
        #expect(finchSD != finchLA, "the same bird in another set is another patch")
        #expect(finchSD.count == 1)
        #expect(finchSD.placement.setID == "us-ca-sd")
        #expect(collection.patches(of: Self.finch).map(\.placement.setID) == ["us-ca-la", "us-ca-sd"], "a species' patches, earliest sewn first")
    }

    @Test("sightings with no location, or outside every set, share the species' Uncharted patch")
    func unchartedPatch() throws {
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1), Self.card(Self.finch, minutes: 5, id: 2, at: CardSetTests.portland)],
            sets: Self.sets
        )
        let patch = try #require(collection.patch(of: Self.uuid(1)))
        #expect(patch.placement == .uncharted)
        #expect(patch.count == 2)
        #expect(collection.patches.count == 1)
    }

    @Test("an add sews a patch only when no surviving sighting of its species is in that placement")
    func addSewsPatch() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1, at: Self.la)], sets: Self.sets)
        #expect(!collection.addSewsPatch(speciesID: Self.finch, at: Self.la), "seen again")
        #expect(collection.addSewsPatch(speciesID: Self.finch, at: Self.sd), "a new place")
        #expect(collection.addSewsPatch(speciesID: Self.phoebe, at: Self.la), "a new bird")
        #expect(collection.addSewsPatch(speciesID: Self.finch, at: nil), "the Uncharted patch is a patch too")
        #expect(collection.count(ofSpeciesID: Self.finch, at: Self.la) == 1)
        #expect(collection.count(ofSpeciesID: Self.finch, at: Self.sd) == 0)
        #expect(CardCollection([]).addSewsPatch(speciesID: Self.finch, at: Self.la))
    }

    @Test("deleting a sighting lowers its patch's count and moves its sewn date on; deleting the last unpicks it")
    func deletion() throws {
        let first = Self.card(Self.finch, minutes: 0, id: 1, at: Self.la)
        let second = Self.card(Self.finch, minutes: 60, id: 2, at: Self.la)
        let third = Self.card(Self.finch, minutes: 30, id: 3, at: Self.la)

        let all = try #require(CardCollection([first, second, third], sets: Self.sets).patch(of: Self.uuid(2)))
        #expect(all.count == 3)
        #expect(all.sewn.identifier == Self.uuid(1))

        let fewer = try #require(CardCollection([second, third], sets: Self.sets).patch(of: Self.uuid(2)))
        #expect(fewer.count == 2)
        #expect(fewer.sewn.identifier == Self.uuid(3))
        #expect(fewer.id == all.id, "the same patch, by species and placement")

        let none = CardCollection([], sets: Self.sets)
        #expect(none.patches.isEmpty)
        #expect(!none.contains(speciesID: Self.finch))
        #expect(CardCollection([second], sets: Self.sets).isLastSighting(of: Self.uuid(2)))
        #expect(!CardCollection([second, third], sets: Self.sets).isLastSighting(of: Self.uuid(2)))
    }

    @Test("two sightings at the same moment: the lower identifier sewed the patch")
    func tiesByIdentifier() throws {
        let collection = CardCollection([Self.card(Self.finch, minutes: 5, id: 9), Self.card(Self.finch, minutes: 5, id: 7)])
        #expect(try #require(collection.patch(of: Self.uuid(9))).sewn.identifier == Self.uuid(7))
        #expect(collection.cards.map(\.identifier) == [Self.uuid(9), Self.uuid(7)], "the earlier sorts as the older")
    }

    @Test("a set's patches in collector-number order")
    func patchesInSet() {
        let collection = CardCollection(
            [Self.card(Self.phoebe, minutes: 0, id: 1, at: Self.la), Self.card(Self.finch, minutes: 5, id: 2, at: Self.la), Self.card(Self.finch, minutes: 9, id: 3, at: Self.sd)],
            sets: Self.sets
        )
        // The finch is 21st in Los Angeles, the phoebe 87th.
        #expect(collection.patches(in: "us-ca-la").map(\.speciesID) == [Self.finch, Self.phoebe])
        #expect(collection.patches(in: "us-ca-sd").map(\.speciesID) == [Self.finch])
        #expect(collection.progress(of: "us-ca-la").collected == 2, "progress counts patches")
    }

    @Test("the summary counts patches and sightings")
    func summary() {
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1), Self.card(Self.finch, minutes: 90, id: 2), Self.card(Self.phoebe, minutes: 9, id: 3)]
        )
        #expect(collection.sightingCount == 3)
        #expect(collection.patchCount == 2)
        #expect(collection.speciesCount == 2)
        #expect(collection.summary == "2 patches, 3 sightings")
        #expect(collection.patchesText == "2 patches")
        #expect(CardCollection([Self.card(Self.finch, minutes: 0, id: 1)]).summary == "1 patch, 1 sighting")
    }

    @Test("seen-again and new-patch lines")
    func patchLines() throws {
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1, at: Self.la), Self.card(Self.finch, minutes: 9, id: 2, at: Self.la)],
            sets: Self.sets
        )
        let patch = try #require(collection.patch(of: Self.uuid(1)))
        #expect(patch.countText == "Seen 2 times")
        #expect(patch.seenAgainText == "Seen 2 times in Los Angeles")
        let single = try #require(CardCollection([Self.card(Self.finch, minutes: 0, id: 1)]).patch(of: Self.uuid(1)))
        #expect(single.countText == "Seen once")
        #expect(single.seenAgainText == "Seen once, Uncharted")
    }

    @Test("the collection reads stored sightings")
    func fromSightings() {
        let sighting = Sighting(identifier: Self.uuid(5), speciesID: Self.finch, confirmedAt: Self.start, soundConfidence: 0.5, source: .phone)
        #expect(CardCollection.Entry(sighting) == Self.card(Self.finch, minutes: 0, id: 5))
    }

    @Test("the intro shows once, the first time the collection has a patch")
    func introShowsOnce() throws {
        let suite = "collection-intro-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intro = CollectionIntro(defaults: defaults)

        #expect(!intro.shouldShow(patchCount: 0), "nothing to show yet")
        #expect(intro.shouldShow(patchCount: 12))
        intro.markShown()
        #expect(!intro.shouldShow(patchCount: 12))
        #expect(!CollectionIntro(defaults: defaults).shouldShow(patchCount: 13), "remembered across launches")
    }
}

// Issue #150: the app keeps one collection instead of building it in every view body. Kept, it has to answer exactly as a
// collection built fresh from the same sightings and sets would, whatever happened on the way there.
@Suite("A kept collection")
struct CardCollectionCacheTests {
    private static let finch = CardCollectionTests.finch
    private static let phoebe = CardCollectionTests.phoebe
    private static let la = CardCollectionTests.la
    private static let sd = CardCollectionTests.sd
    private static let sets = CardCollectionTests.sets

    private static func card(_ species: String, minutes: Double, id: Int, at place: Coordinate? = nil) -> CardCollection.Entry {
        CardCollectionTests.card(species, minutes: minutes, id: id, at: place)
    }

    @Test("it answers as a fresh one does through adds, removals, a moved sighting and a newly known set")
    func answersAsAFreshOneDoes() {
        let first = Self.card(Self.finch, minutes: 10, id: 1, at: Self.la)
        let second = Self.card(Self.phoebe, minutes: 20, id: 2, at: Self.la)
        let third = Self.card(Self.finch, minutes: 30, id: 3, at: Self.sd)
        let moved = Self.card(Self.phoebe, minutes: 20, id: 2, at: Self.sd)

        var cache = CardCollectionCache([first], sets: [])
        let steps: [(entries: [CardCollection.Entry], sets: [CardSet])] = [
            ([first, second], []),  // an add before the set is known
            ([first, second], Self.sets),  // the set arrives and pulls older sightings in
            ([third, first, second], Self.sets),  // an add, in a different order
            ([third, first, moved], Self.sets),  // a sighting's place corrected
            ([third, moved], Self.sets),  // a removal that unpicks a patch
            ([], Self.sets),  // the last one goes
        ]
        for step in steps {
            cache.update(step.entries, sets: step.sets)
            #expect(cache.collection == CardCollection(step.entries, sets: step.sets))
        }
    }

    @Test("it builds again only when the sightings or the sets changed")
    func buildsOnlyOnAChange() {
        let first = Self.card(Self.finch, minutes: 10, id: 1, at: Self.la)
        let second = Self.card(Self.phoebe, minutes: 20, id: 2, at: Self.la)

        var cache = CardCollectionCache([first], sets: Self.sets)
        let unchanged = cache.update([first], sets: Self.sets)
        #expect(!unchanged)
        let added = cache.update([first, second], sets: Self.sets)
        #expect(added)
        let again = cache.update([first, second], sets: Self.sets)
        #expect(!again)
        let setsChanged = cache.update([first, second], sets: [])
        #expect(setsChanged)
    }
}
