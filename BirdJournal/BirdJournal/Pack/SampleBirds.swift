import Pack

/// The bundled pack's birds the app itself names (#209): the sample patches a birder with no Guild sees and, in DEBUG builds, the
/// seeded journal, the fake Guild, the sample push and the previews. They show these birds' patches from the bundled pack, so the
/// pack must list and paint them. This is the one place in the app that names them, beside `PackIndex.bundledPackID`: a change of
/// bundled pack edits this file. The tests keep their own list, `BundledPack` in `BirdJournalKit/Tests/Support`, and the two must
/// agree on the birds the seeds add.
nonisolated enum SampleBirds {
    nonisolated struct Bird: Sendable {
        let scientificName: String
        let commonName: String

        init(_ scientificName: String, _ commonName: String) {
            self.scientificName = scientificName
            self.commonName = commonName
        }

        /// The species id an add would write for it, the identification model's label.
        var label: String { "\(scientificName)_\(commonName)" }
        /// The stem of its files in a pack, "sayornis-nigricans".
        var slug: String { scientificName.lowercased().replacing(" ", with: "-") }
    }

    /// The set the samples are in, which is also their edition: the bundled pack's.
    static let setID = PackIndex.bundledPackID

    static let finch = Bird("Haemorhous mexicanus", "House Finch")
    static let phoebe = Bird("Sayornis nigricans", "Black Phoebe")
    static let hummingbird = Bird("Calypte anna", "Anna's Hummingbird")
    static let dove = Bird("Zenaida macroura", "Mourning Dove")
    static let goose = Bird("Branta canadensis", "Canada Goose")
    static let woodpecker = Bird("Melanerpes formicivorus", "Acorn Woodpecker")
    static let bluebird = Bird("Sialia mexicana", "Western Bluebird")
    static let egret = Bird("Ardea alba", "Great Egret")
    /// A bird that is rare where the fake Guild's friends are.
    static let rarity = Bird("Polioptila californica", "California Gnatcatcher")
    /// Two a friend has and the seeded journal never does.
    static let friendsOnly = [Bird("Alopochen aegyptiaca", "Egyptian Goose"), Bird("Cairina moschata", "Muscovy Duck")]

    /// Thirty more, for a seeded goal's head start: the last of them newest, as the reference's row runs.
    static let goalBirds = [
        Bird("Buteo jamaicensis", "Red-tailed Hawk"), Bird("Anas platyrhynchos", "Mallard"), Bird("Melozone crissalis", "California Towhee"),
        Bird("Spinus psaltria", "Lesser Goldfinch"), Bird("Mimus polyglottos", "Northern Mockingbird"), goose, egret,
        Bird("Callipepla californica", "California Quail"), bluebird, dove, Bird("Melospiza melodia", "Song Sparrow"),
        Bird("Corvus brachyrhynchos", "American Crow"), Bird("Pipilo maculatus", "Spotted Towhee"), Bird("Ardea herodias", "Great Blue Heron"),
        Bird("Bubo virginianus", "Great Horned Owl"), Bird("Cathartes aura", "Turkey Vulture"), Bird("Junco hyemalis", "Dark-eyed Junco"),
        Bird("Passer domesticus", "House Sparrow"), Bird("Larus occidentalis", "Western Gull"), Bird("Columba livia", "Rock Dove"),
        Bird("Fulica americana", "American Coot"), Bird("Corvus corax", "Northern Raven"), Bird("Egretta thula", "Snowy Egret"),
        Bird("Buteo lineatus", "Red-shouldered Hawk"), Bird("Astur cooperii", "Cooper's Hawk"), Bird("Selasphorus sasin", "Allen's Hummingbird"),
        Bird("Psaltriparus minimus", "American Bushtit"), Bird("Tyrannus vociferans", "Cassin's Kingbird"), Bird("Icterus cucullatus", "Hooded Oriole"),
        Bird("Dryobates nuttallii", "Nuttall's Woodpecker"),
    ]
}
