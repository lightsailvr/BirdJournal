import Foundation
import Testing
@testable import Album

// Issue #54: cards belong to sets. A card's set is the smallest region whose boundary contains the sighting and whose
// species list includes the species, otherwise Uncharted, which also takes every sighting with no location. The
// collector number is the species' place in its set's taxonomic order. Membership is computed, never stored.
@Suite("Card sets")
struct CardSetTests {
    static let finch = "Haemorhous mexicanus_House Finch"
    static let phoebe = "Sayornis nigricans_Black Phoebe"
    static let thrasher = "Toxostoma lecontei_LeConte's Thrasher"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Boxes close to the real regions, [longitude, latitude].
    static let sanDiegoCounty = ring([(-117.6, 32.53), (-116.08, 32.53), (-116.08, 33.51), (-117.6, 33.51)])
    static let anzaBorrego = ring([(-116.57, 32.70), (-116.05, 32.70), (-116.05, 33.50), (-116.57, 33.50)])
    static let imperialCounty = ring([(-116.10, 32.62), (-114.46, 32.62), (-114.46, 33.43), (-116.10, 33.43)])
    static let losAngelesCounty = ring([(-118.95, 33.70), (-117.65, 33.70), (-117.65, 34.82), (-118.95, 34.82)])

    static let borregoSprings = Coordinate(latitude: 33.25, longitude: -116.40, accuracy: 10)
    static let balboaPark = Coordinate(latitude: 32.73, longitude: -117.15, accuracy: 10)
    static let griffithPark = Coordinate(latitude: 34.13, longitude: -118.29, accuracy: 10)
    static let portland = Coordinate(latitude: 45.52, longitude: -122.68, accuracy: 10)

    /// The San Diego set: the finch and the phoebe among 159 species, the phoebe 21st.
    static let sanDiego = CardSet(
        id: "us-ca-sd", name: "San Diego", edition: "Coastal edition",
        species: species(count: 159, placing: [21: "Sayornis nigricans", 140: "Haemorhous mexicanus"]),
        regions: [CardSet.Region(name: "San Diego County", polygons: [[sanDiegoCounty]])]
    )
    /// The Deserts set: the finch and the thrasher, no phoebe; Anza-Borrego is a small part inside San Diego County.
    static let deserts = CardSet(
        id: "us-ca-desert", name: "California Deserts", edition: "Desert edition",
        species: species(count: 155, placing: [7: "Toxostoma lecontei", 150: "Haemorhous mexicanus"]),
        regions: [
            CardSet.Region(name: "Imperial County", polygons: [[imperialCounty]]),
            CardSet.Region(name: "Anza-Borrego Desert State Park", polygons: [[anzaBorrego]]),
        ]
    )
    static let losAngeles = CardSet(
        id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition",
        species: species(count: 160, placing: [21: "Haemorhous mexicanus", 87: "Sayornis nigricans"]),
        regions: [CardSet.Region(name: "Los Angeles County", polygons: [[losAngelesCounty]])]
    )
    static let sets = [losAngeles, sanDiego, deserts]

    static func ring(_ corners: [(Double, Double)]) -> [CardSet.Point] {
        (corners + [corners[0]]).map { CardSet.Point(longitude: $0.0, latitude: $0.1) }
    }

    /// `count` species in order, with the given ones at their 1-based positions and fillers elsewhere.
    static func species(count: Int, placing: [Int: String]) -> [String] {
        (1...count).map { placing[$0] ?? "Avis filler\($0)" }
    }

    static func card(_ species: String, at place: Coordinate?, minutes: Double = 0, id: Int) -> CardCollection.Entry {
        CardCollection.Entry(identifier: uuid(id), speciesID: species, confirmedAt: start.addingTimeInterval(minutes * 60), location: place)
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test("an Anza-Borrego point inside San Diego County goes to the Deserts set: the smallest region wins")
    func smallestRegionWins() {
        let collection = CardCollection([Self.card(Self.finch, at: Self.borregoSprings, id: 1)], sets: Self.sets)
        #expect(collection.placement(of: Self.uuid(1)) == .numbered(setID: "us-ca-desert", setName: "California Deserts", edition: "Desert edition", number: 150, total: 155))
        #expect(collection.placement(of: Self.uuid(1))?.collectorNumber == "150/155")
    }

    @Test("a species the smaller set lacks goes to the larger set that has it")
    func smallerSetWithoutTheSpecies() {
        let collection = CardCollection([Self.card(Self.phoebe, at: Self.borregoSprings, id: 1)], sets: Self.sets)
        #expect(collection.placement(of: Self.uuid(1))?.setID == "us-ca-sd")
        #expect(collection.placement(of: Self.uuid(1))?.collectorNumber == "021/159")
    }

    @Test("a species no containing set lists is Uncharted, and so is a sighting with no location or outside every set")
    func uncharted() {
        let collection = CardCollection(
            [
                Self.card(Self.thrasher, at: Self.griffithPark, id: 1),
                Self.card(Self.finch, at: nil, id: 2),
                Self.card(Self.finch, at: Self.portland, id: 3),
            ],
            sets: Self.sets
        )
        for id in 1...3 {
            #expect(collection.placement(of: Self.uuid(id)) == .uncharted)
            #expect(collection.placement(of: Self.uuid(id))?.collectorNumber == "Uncharted")
        }
        #expect(collection.unchartedSpeciesCount == 2)
    }

    @Test("collector numbers pad to three digits, or to the set's size when it is larger")
    func collectorNumberText() {
        #expect(CardPlacement.numbered(setID: "a", setName: "A", edition: "E", number: 21, total: 160).collectorNumber == "021/160")
        #expect(CardPlacement.numbered(setID: "a", setName: "A", edition: "E", number: 3, total: 40).collectorNumber == "003/040")
        #expect(CardPlacement.numbered(setID: "a", setName: "A", edition: "E", number: 21, total: 1200).collectorNumber == "0021/1200")
    }

    @Test("set progress counts the distinct species of the set's own cards, not cards, and not finds elsewhere")
    func progress() {
        let collection = CardCollection(
            [
                Self.card(Self.finch, at: Self.griffithPark, minutes: 0, id: 1),
                Self.card(Self.finch, at: Self.griffithPark, minutes: 5, id: 2),
                Self.card(Self.phoebe, at: Self.griffithPark, minutes: 10, id: 3),
                Self.card(Self.phoebe, at: Self.balboaPark, minutes: 15, id: 4),
                Self.card(Self.finch, at: nil, minutes: 20, id: 5),
            ],
            sets: Self.sets
        )
        let losAngeles = collection.progress(of: "us-ca-la")
        #expect(losAngeles == SetProgress(setID: "us-ca-la", name: "Los Angeles", collected: 2, total: 160))
        #expect(losAngeles.text == "Los Angeles · 2 of 160")
        #expect(collection.progress(of: "us-ca-sd").collected == 1, "the phoebe; the finch was never added in San Diego")
        #expect(collection.progress(of: "us-ca-desert").collected == 0)
        #expect(collection.progress.map(\.setID) == ["us-ca-la", "us-ca-sd"], "only sets with a card, most collected first")
        #expect(collection.collected(in: "us-ca-la") == ["Haemorhous mexicanus", "Sayornis nigricans"])
        #expect(collection.collected(in: "us-ca-sd") == ["Sayornis nigricans"])
    }

    @Test("a newly known set pulls older sightings in")
    func newSetPullsOlderSightingsIn() {
        let entries = [Self.card(Self.finch, at: Self.balboaPark, id: 1)]
        #expect(CardCollection(entries, sets: [Self.losAngeles]).placement(of: Self.uuid(1)) == .uncharted)
        #expect(CardCollection(entries, sets: [Self.losAngeles, Self.sanDiego]).placement(of: Self.uuid(1))?.collectorNumber == "140/159")
    }

    @Test("a card that is not Legendary shows its set's edition, an Uncharted one says so, and a Legendary one shows none")
    func editionLabel() {
        let collection = CardCollection(
            [
                Self.card(Self.finch, at: Self.griffithPark, minutes: 0, id: 1),
                Self.card(Self.finch, at: Self.griffithPark, minutes: 5, id: 2),
                Self.card(Self.finch, at: nil, minutes: 10, id: 3),
            ],
            sets: Self.sets
        )
        #expect(collection.editionLabel(of: Self.uuid(1)) == nil, "Legendary")
        #expect(collection.editionLabel(of: Self.uuid(2)) == "Citrus edition")
        #expect(collection.editionLabel(of: Self.uuid(3)) == "Uncharted")
        #expect(collection.placement(of: Self.uuid(1))?.collectorNumber == "021/160", "a Legendary card keeps its number")
    }

    @Test("an add is placed before its sighting exists, as the collection will place it")
    func placementOfAnAdd() {
        #expect(CardSet.placement(speciesID: Self.finch, at: Self.borregoSprings, in: Self.sets).setID == "us-ca-desert")
        #expect(CardSet.placement(speciesID: Self.finch, at: nil, in: Self.sets) == .uncharted)
    }

    @Test("a hole in a region is outside it, and a region's area takes its holes out")
    func holes() {
        let outer = Self.ring([(-118, 34), (-117, 34), (-117, 35), (-118, 35)])
        let hole = Self.ring([(-117.75, 34.25), (-117.25, 34.25), (-117.25, 34.75), (-117.75, 34.75)])
        let region = CardSet.Region(name: "Ring", polygons: [[outer, hole]])
        #expect(region.contains(latitude: 34.1, longitude: -117.9))
        #expect(!region.contains(latitude: 34.5, longitude: -117.5))
        #expect(!region.contains(latitude: 36, longitude: -117.5))
        let expected = 111.32 * cos(34.5 * .pi / 180) * 110.57 * 0.75
        #expect(abs(region.area - expected) / expected < 0.01)
    }

    @Test("without sets every card is Uncharted, as before sets existed")
    func noSets() {
        let collection = CardCollection([Self.card(Self.finch, at: Self.griffithPark, id: 1)])
        #expect(collection.placement(of: Self.uuid(1)) == .uncharted)
        #expect(collection.progress.isEmpty)
    }
}
