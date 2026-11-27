import Foundation
import PackFixture
import Testing
@testable import Pack

/// `BundledPack` is what every test knows of the pack that ships (#209). These check it against that pack, so a change
/// of bundled pack that misses the list fails here first, and says what to edit.
@Suite("What the tests know of the bundled pack")
struct BundledPackFixtureTests {
    @Test("it names the pack that ships: its id, its set's name, its edition and how many birds it lists")
    func namesThePackThatShips() throws {
        let pack = try SpeciesPack.bundled()
        let set = try #require(pack.set)
        #expect(BundledPack.id == PackIndex.bundledPackID && BundledPack.id == pack.info.id)
        #expect(BundledPack.setName == set.name)
        #expect(BundledPack.editionName == set.edition.name)
        #expect(BundledPack.speciesCount == set.species.count)
    }

    @Test("each of its birds is in the pack under that name, at that collector number, with a patch")
    func itsBirdsAreThePacks() throws {
        let pack = try SpeciesPack.bundled()
        let set = try #require(pack.set)
        #expect(Set(BundledPack.all.map(\.scientificName)).count == BundledPack.all.count, "a bird is listed twice")
        for bird in BundledPack.all {
            let species = try #require(pack.species(scientificName: bird.scientificName), "\(bird.name) is not in \(pack.info.id)")
            #expect(species.commonName == bird.name)
            #expect(set.species.firstIndex { $0.scientificName == bird.scientificName }.map { $0 + 1 } == bird.number, "\(bird.name)'s collector number")
            #expect(species.patch != nil, "\(bird.name) has no patch")
        }
    }

    @Test("the birds it singles out by their place are in that place")
    func placesInThePack() throws {
        let pack = try SpeciesPack.bundled()
        #expect(BundledPack.goose.number == 1, "the set's first bird")
        #expect(BundledPack.otherGoose.number == BundledPack.goose.number + 1)
        #expect(pack.species.first?.scientificName == BundledPack.hawk.scientificName, "the first in the pack's own order")
        #expect(BundledPack.otherHummingbird.number == BundledPack.hummingbird.number + 1 && BundledPack.otherHummingbird.genus != BundledPack.hummingbird.genus)
        #expect(!pack.species.prefix(30).contains { $0.scientificName == BundledPack.gnatcatcher.scientificName }, "not among the thirty `-seedBoard` adds")
        #expect([BundledPack.dove, BundledPack.phoebe, BundledPack.finch].map(\.number) == [BundledPack.dove, BundledPack.phoebe, BundledPack.finch].map(\.number).sorted(), "the seeded birds' collector order")
    }
}
