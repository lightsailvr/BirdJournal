import Foundation
import Testing
@testable import Album

// Issue #134: a board shows only the patches you've sewn, in collector-number order, and a patch's page swipes through all
// of them.
@Suite("Patch board")
struct PatchBoardTests {
    static let finch = CardCollectionTests.finch
    static let phoebe = CardCollectionTests.phoebe
    static let la = CardCollectionTests.la
    static let sd = CardCollectionTests.sd

    static let set = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Sayornis nigricans", "Calypte anna", "Haemorhous mexicanus"], regions: CardSetTests.sets[0].regions)

    static func card(_ species: String, minutes: Double, id: Int, at place: Coordinate? = nil) -> CardCollection.Entry {
        CardCollectionTests.card(species, minutes: minutes, id: id, at: place)
    }

    @Test("a set's patches are the birds you've sewn there, in collector order: no others")
    func boardOrder() throws {
        let set = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Anas platyrhynchos", "Sayornis nigricans", "Calypte anna", "Haemorhous mexicanus"], regions: Self.set.regions)
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1, at: Self.la), Self.card(Self.finch, minutes: 5, id: 2, at: Self.la), Self.card(Self.phoebe, minutes: 9, id: 3, at: Self.la)],
            sets: [set]
        )
        let patches = collection.patches(in: "us-ca-la")
        #expect(patches.map(\.scientificName) == ["Sayornis nigricans", "Haemorhous mexicanus"])
        #expect(patches.map(\.count) == [1, 2])
    }

    @Test("a sighting in another place doesn't sew this set's patch; a set the collection doesn't know has none")
    func otherPlaces() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1, at: Self.sd), Self.card(Self.phoebe, minutes: 1, id: 2)], sets: [Self.set] + CardSetTests.sets.dropFirst())
        #expect(collection.patches(in: "us-ca-la").isEmpty)
        #expect(collection.patches(in: "nowhere").isEmpty)
    }

    @Test("Uncharted patches are the patches outside every set, the most recently sewn first")
    func uncharted() {
        let collection = CardCollection(
            [Self.card(Self.phoebe, minutes: 0, id: 1), Self.card(Self.finch, minutes: 5, id: 2), Self.card(Self.finch, minutes: 9, id: 3, at: Self.la)],
            sets: [Self.set]
        )
        #expect(collection.unchartedPatches.map(\.scientificName) == ["Haemorhous mexicanus", "Sayornis nigricans"])
    }

    @Test("a page swipes through every patch: each set as known, in collector order, then Uncharted")
    func browsingOrder() {
        let collection = CardCollection(
            [
                Self.card(Self.finch, minutes: 0, id: 1, at: Self.sd),
                Self.card(Self.finch, minutes: 1, id: 2, at: Self.la),
                Self.card(Self.phoebe, minutes: 2, id: 3, at: Self.la),
                Self.card(Self.phoebe, minutes: 3, id: 4),
                Self.card(Self.finch, minutes: 4, id: 5),
            ],
            sets: [Self.set, CardSetTests.sanDiego]
        )
        let order = collection.browsingOrder.map { "\($0.scientificName) \($0.placement.setID ?? "uncharted")" }
        #expect(order == [
            "Sayornis nigricans us-ca-la", "Haemorhous mexicanus us-ca-la",
            "Haemorhous mexicanus us-ca-sd",
            "Haemorhous mexicanus uncharted", "Sayornis nigricans uncharted",
        ])
        #expect(Set(collection.browsingOrder) == Set(collection.patches), "every patch, once")
    }

    @Test("a species' summary reads its patches, its sightings across them and when it was first sewn")
    func speciesSummary() throws {
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1, at: Self.la), Self.card(Self.finch, minutes: 5, id: 2, at: Self.la), Self.card(Self.finch, minutes: 9, id: 3, at: Self.sd)],
            sets: CardSetTests.sets
        )
        let patches = collection.patches(of: Self.finch)
        #expect(CardCollection.Patch.speciesSummary(patches) == "2 patches · seen 3 times")
        #expect(CardCollection.Patch.speciesSummary(Array(patches.prefix(1))) == "1 patch · seen 2 times")
    }
}
