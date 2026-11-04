import Foundation
import Testing
@testable import Album

// Issue #134 (guide pages 6 and 7): a set's felt board shows one place per species in collector-number order, your
// patch where you've sewn one and its pattern where you haven't; a species' page shows the editions still to find.
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

    @Test("the board lists your patches in collector order, then the patterns of the birds still to find, also in order")
    func boardOrder() throws {
        let set = CardSet(id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition", species: ["Anas platyrhynchos", "Sayornis nigricans", "Calypte anna", "Haemorhous mexicanus"], regions: Self.set.regions)
        let collection = CardCollection(
            [Self.card(Self.finch, minutes: 0, id: 1, at: Self.la), Self.card(Self.finch, minutes: 5, id: 2, at: Self.la), Self.card(Self.phoebe, minutes: 9, id: 3, at: Self.la)],
            sets: [set]
        )

        let board = collection.board(of: "us-ca-la")

        #expect(board.map(\.scientificName) == ["Sayornis nigricans", "Haemorhous mexicanus", "Anas platyrhynchos", "Calypte anna"])
        #expect(board.map(\.number) == [2, 4, 1, 3], "each keeps its collector number")
        #expect(board.map(\.total) == [4, 4, 4, 4])
        #expect(board[0].patch?.count == 1)
        #expect(board[1].patch?.count == 2)
        #expect(board[2].patch == nil && board[3].patch == nil, "not found yet: patterns")
    }

    @Test("a sighting in another place doesn't sew this board's patch")
    func otherPlaces() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1, at: Self.sd), Self.card(Self.phoebe, minutes: 1, id: 2)], sets: [Self.set] + CardSetTests.sets.dropFirst())
        #expect(collection.board(of: "us-ca-la").allSatisfy { $0.patch == nil })
    }

    @Test("a set the collection doesn't know has no board")
    func unknownSet() {
        #expect(CardCollection([], sets: [Self.set]).board(of: "nowhere").isEmpty)
    }

    @Test("Uncharted patches are the patches outside every set, the most recently sewn first")
    func uncharted() {
        let collection = CardCollection(
            [Self.card(Self.phoebe, minutes: 0, id: 1), Self.card(Self.finch, minutes: 5, id: 2), Self.card(Self.finch, minutes: 9, id: 3, at: Self.la)],
            sets: [Self.set]
        )
        #expect(collection.unchartedPatches.map(\.scientificName) == ["Haemorhous mexicanus", "Sayornis nigricans"])
    }

    @Test("the editions still to find are the sets listing the bird where it has no patch")
    func stillToFind() {
        let collection = CardCollection([Self.card(Self.finch, minutes: 0, id: 1, at: Self.la)], sets: CardSetTests.sets)
        let listing = CardSetTests.sets.filter { $0.number(of: "Haemorhous mexicanus") != nil }.map(\.id)
        #expect(listing.contains("us-ca-la"), "the fixture lists the finch in Los Angeles")
        #expect(collection.setsToFind(scientificName: "Haemorhous mexicanus").map(\.id) == listing.filter { $0 != "us-ca-la" })
        #expect(collection.setsToFind(scientificName: "Turdus merula").isEmpty, "no set lists it")
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
