import Pack
import Testing
@testable import BirdJournal

/// `SampleBirds` is the one place the app names the bundled pack's birds (#209), for its sample patches, seeds and fake
/// Guild. These check it against the pack that ships and against the tests' own list, `BundledPack`.
@Suite("The app's sample birds")
struct SampleBirdsTests {
    static let named = [
        SampleBirds.finch, SampleBirds.phoebe, SampleBirds.hummingbird, SampleBirds.dove, SampleBirds.goose, SampleBirds.woodpecker,
        SampleBirds.bluebird, SampleBirds.egret, SampleBirds.rarity,
    ]

    @Test("every sample bird is in the bundled pack under that name, with a patch to show")
    func inTheBundledPack() throws {
        let pack = try SpeciesPack.bundled()
        #expect(SampleBirds.setID == pack.info.id)
        for bird in Self.named + SampleBirds.friendsOnly + SampleBirds.goalBirds {
            let species = try #require(pack.species(scientificName: bird.scientificName), "\(bird.commonName) is not in \(pack.info.id)")
            #expect(species.commonName == bird.commonName)
            #expect(species.patch != nil, "\(bird.commonName) has no patch")
        }
    }

    @Test("the tests' list names the same birds, so what a seed adds is what a test expects")
    func agreesWithTheTestsList() {
        let pairs = [
            (SampleBirds.finch, BundledPack.finch), (SampleBirds.phoebe, BundledPack.phoebe), (SampleBirds.hummingbird, BundledPack.hummingbird),
            (SampleBirds.dove, BundledPack.dove), (SampleBirds.goose, BundledPack.goose), (SampleBirds.woodpecker, BundledPack.woodpecker),
            (SampleBirds.bluebird, BundledPack.bluebird), (SampleBirds.egret, BundledPack.egret), (SampleBirds.rarity, BundledPack.gnatcatcher),
            (SampleBirds.friendsOnly[0], BundledPack.otherGoose), (SampleBirds.friendsOnly[1], BundledPack.duck),
        ]
        for (sample, known) in pairs {
            #expect(sample.label == known.label)
        }
        #expect(SampleBirds.setID == BundledPack.id)
    }
}
