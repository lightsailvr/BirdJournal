import Foundation
import Testing
@testable import Album

// Issue #207 (of #206): a sighting is placed among the sets it is given, which the app makes the sets whose pack is on the
// phone. A continent-sized set and a regional one inside it: the regional set wins where both list the bird, the larger
// one takes what the regional set lacks, and a set that is left out (its field guide deleted) hands its sightings to
// the larger set, or to Uncharted, with nothing about the patch changing but where it is filed.
@Suite("Sets on the phone")
struct SetsOnThePhoneTests {
    static let robin = "Turdus migratorius_American Robin"
    static let jay = "Cyanocitta stelleri_Steller's Jay"
    static let cardinal = "Cardinalis cardinalis_Northern Cardinal"
    static let hoopoe = "Upupa epops_Eurasian Hoopoe"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Boxes, [longitude, latitude]: the lower 48 and southern Canada, and western Washington and Oregon inside it.
    static let continent = CardSetTests.ring([(-125, 25), (-60, 25), (-60, 60), (-125, 60)])
    static let northwest = CardSetTests.ring([(-124.8, 42), (-121, 42), (-121, 49), (-124.8, 49)])

    static let seattle = Coordinate(latitude: 47.61, longitude: -122.33, accuracy: 10)
    static let chicago = Coordinate(latitude: 41.88, longitude: -87.63, accuracy: 10)
    static let london = Coordinate(latitude: 51.51, longitude: -0.13, accuracy: 10)

    /// The continent-sized set: the robin, the jay and the cardinal among 300 species.
    static let continental = CardSet(
        id: "north-america", name: "North America", edition: "Continental edition",
        species: CardSetTests.species(count: 300, placing: [120: "Cyanocitta stelleri", 210: "Turdus migratorius", 280: "Cardinalis cardinalis"]),
        regions: [CardSet.Region(name: "United States and Canada", polygons: [[continent]])]
    )
    /// The regional set inside it: the robin and the jay, no cardinal.
    static let regional = CardSet(
        id: "us-pnw", name: "Pacific Northwest", edition: "Evergreen edition",
        species: CardSetTests.species(count: 150, placing: [60: "Cyanocitta stelleri", 101: "Turdus migratorius"]),
        regions: [CardSet.Region(name: "Western Washington and Oregon", polygons: [[northwest]])]
    )

    static func sighting(_ species: String, at place: Coordinate?, minutes: Double = 0, id: Int) -> CardCollection.Entry {
        CardCollection.Entry(identifier: CardSetTests.uuid(id), speciesID: species, confirmedAt: start.addingTimeInterval(minutes * 60), location: place)
    }

    @Test("inside the regional set's place, a bird both sets list is the regional set's")
    func regionalSetWinsInsideItsPlace() {
        for sets in [[Self.continental, Self.regional], [Self.regional, Self.continental]] {
            let placement = CardSet.placement(speciesID: Self.robin, at: Self.seattle, in: sets)
            #expect(placement == .numbered(setID: "us-pnw", setName: "Pacific Northwest", edition: "Evergreen edition", number: 101, total: 150))
        }
    }

    @Test("the larger set takes a bird only it lists, and any bird of its own outside the regional set's place")
    func largerSetTakesWhatTheRegionalSetDoesNot() {
        let sets = [Self.continental, Self.regional]
        #expect(CardSet.placement(speciesID: Self.cardinal, at: Self.seattle, in: sets).collectorNumber == "280/300", "inside the region, which doesn't list it")
        #expect(CardSet.placement(speciesID: Self.cardinal, at: Self.seattle, in: sets).setID == "north-america")
        #expect(CardSet.placement(speciesID: Self.robin, at: Self.chicago, in: sets).setID == "north-america", "listed by both, outside the region")
        #expect(CardSet.placement(speciesID: Self.robin, at: Self.chicago, in: sets).editionLabel == "Continental edition")
    }

    @Test("outside both sets, with no location, or for a bird neither lists: Uncharted")
    func unchartedOutsideBoth() {
        let sets = [Self.continental, Self.regional]
        #expect(CardSet.placement(speciesID: Self.robin, at: Self.london, in: sets) == .uncharted)
        #expect(CardSet.placement(speciesID: Self.robin, at: nil, in: sets) == .uncharted)
        #expect(CardSet.placement(speciesID: Self.hoopoe, at: Self.seattle, in: sets) == .uncharted)
    }

    @Test("leaving the regional set out moves its sightings to the larger set, and giving it back moves them again; the count and the sewn date don't change")
    func aSetLeftOutHandsItsSightingsOn() throws {
        let sightings = [
            Self.sighting(Self.robin, at: Self.seattle, minutes: 30, id: 1),
            Self.sighting(Self.robin, at: Self.seattle, minutes: 10, id: 2),
            Self.sighting(Self.robin, at: Self.seattle, minutes: 20, id: 3),
        ]
        let both = CardCollection(sightings, sets: [Self.continental, Self.regional])
        let withoutRegional = CardCollection(sightings, sets: [Self.continental])
        let again = CardCollection(sightings, sets: [Self.continental, Self.regional])

        let regionalPatch = try #require(both.patch(of: CardSetTests.uuid(1)))
        #expect(regionalPatch.placement.setID == "us-pnw")
        #expect(both.progress(of: "us-pnw").collected == 1 && both.progress(of: "north-america").collected == 0)

        let moved = try #require(withoutRegional.patch(of: CardSetTests.uuid(1)))
        #expect(moved.placement == .numbered(setID: "north-america", setName: "North America", edition: "Continental edition", number: 210, total: 300))
        #expect(withoutRegional.patches.count == 1, "one patch, moved, not a second one")
        #expect(moved.count == 3)
        #expect(moved.sewn.identifier == CardSetTests.uuid(2) && moved.sewn.confirmedAt == Self.start.addingTimeInterval(600), "sewn by the same sighting, on the same date")
        #expect(moved.sightings == regionalPatch.sightings)
        #expect(withoutRegional.progress(of: "north-america").collected == 1)
        #expect(withoutRegional.cards == both.cards, "the sightings themselves are as they were")

        let back = try #require(again.patch(of: CardSetTests.uuid(1)))
        #expect(back == regionalPatch, "the regional patch again, as it was")
        #expect(again == both)
    }

    @Test("a moved patch is one the birder already has: another sighting there is seen again, not sewn")
    func aMovedPatchIsNotSewnAgain() {
        let sightings = [Self.sighting(Self.robin, at: Self.seattle, id: 1)]
        for sets in [[Self.continental, Self.regional], [Self.continental], []] {
            let collection = CardCollection(sightings, sets: sets)
            #expect(!collection.addSewsPatch(speciesID: Self.robin, at: Self.seattle), "\(sets.map(\.id))")
            #expect(collection.count(ofSpeciesID: Self.robin, at: Self.seattle) == 1)
            #expect(collection.sewedItsPatch(CardSetTests.uuid(1)))
        }
    }

    @Test("with no larger set to take them, a left-out set's sightings are Uncharted until it is given back")
    func leftOutWithNothingLargerIsUncharted() throws {
        let sightings = [Self.sighting(Self.jay, at: Self.seattle, minutes: 0, id: 1), Self.sighting(Self.jay, at: Self.seattle, minutes: 5, id: 2)]
        let without = CardCollection(sightings, sets: [])
        let patch = try #require(without.patch(of: CardSetTests.uuid(2)))
        #expect(patch.placement == .uncharted && patch.count == 2 && patch.sewn.identifier == CardSetTests.uuid(1))
        #expect(without.unchartedSpeciesCount == 1 && without.progress.isEmpty)

        let with = CardCollection(sightings, sets: [Self.regional])
        #expect(with.patch(of: CardSetTests.uuid(2))?.placement.collectorNumber == "060/150")
        #expect(with.patch(of: CardSetTests.uuid(2))?.count == 2)
        #expect(with.patch(of: CardSetTests.uuid(2))?.sewn.identifier == CardSetTests.uuid(1))
        #expect(with.unchartedSpeciesCount == 0)
    }
}
