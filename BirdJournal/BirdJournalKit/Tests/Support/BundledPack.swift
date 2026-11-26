// What the tests know of the pack that ships in the app (#209), in one place. Every test target reads it: the package's
// test targets import it as the `PackFixture` module, and the app's two test targets compile this file in.
//
// A test whose subject is the bundled pack, or the app running on it (every UI test), asks here for the pack's id, its
// set's name and its birds, and never names them itself. So a change of bundled pack (#220) edits this file, the app's
// own `SampleBirds`, and the tests tagged `losAngelesContent` or marked "Los Angeles content", and nothing else.

/// The bundled pack: Los Angeles today.
public enum BundledPack {
    /// The pack's id, which is also its set's.
    public static let id = "us-ca-la"
    /// Its set's name, as a birder reads it.
    public static let setName = "Los Angeles"
    /// Its edition's name.
    public static let editionName = "Citrus edition"
    /// How many birds its set lists.
    public static let speciesCount = 160

    /// A bird the bundled pack lists, with a patch.
    public struct Bird: Sendable, Equatable {
        public let scientificName: String
        /// Its common name, as the pack spells it.
        public let name: String
        /// Its 1-based place in the set's taxonomic order: its collector number.
        public let number: Int

        public init(_ scientificName: String, _ name: String, number: Int) {
            self.scientificName = scientificName
            self.name = name
            self.number = number
        }

        /// A sighting's species id for it, in the shape of a BirdNET label. The app finds the bird by the scientific name
        /// in it.
        public var label: String { "\(scientificName)_\(name)" }
        /// "130", "001": the collector number as a set's page prints it.
        public var paddedNumber: String {
            let digits = String(number)
            return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        }
    }

    // The birds the tests use, named by kind so that another pack's can stand in. `-seedJournal` (the app's
    // `SampleBirds`) adds the finch twice, the phoebe, the dove and, with no location, the hummingbird.
    public static let finch = Bird("Haemorhous mexicanus", "House Finch", number: 130)
    public static let phoebe = Bird("Sayornis nigricans", "Black Phoebe", number: 85)
    /// A second bird of the phoebe's genus, so a search for the genus finds two.
    public static let otherPhoebe = Bird("Sayornis saya", "Say's Phoebe", number: 86)
    public static let hummingbird = Bird("Calypte anna", "Anna's Hummingbird", number: 21)
    /// The bird after the hummingbird in the set, and a second hummingbird.
    public static let otherHummingbird = Bird("Selasphorus sasin", "Allen's Hummingbird", number: 22)
    public static let dove = Bird("Zenaida macroura", "Mourning Dove", number: 27)
    /// The set's first bird.
    public static let goose = Bird("Branta canadensis", "Canada Goose", number: 1)
    public static let mallard = Bird("Anas platyrhynchos", "Mallard", number: 9)
    public static let egret = Bird("Ardea alba", "Great Egret", number: 60)
    /// The first bird in the pack's own order, which `-seedBoard` adds first.
    public static let hawk = Bird("Buteo jamaicensis", "Red-tailed Hawk", number: 69)
    public static let woodpecker = Bird("Melanerpes formicivorus", "Acorn Woodpecker", number: 74)
    public static let jay = Bird("Aphelocoma californica", "California Scrub Jay", number: 98)
    public static let raven = Bird("Corvus corax", "Northern Raven", number: 100)
    public static let wren = Bird("Troglodytes aedon", "Northern House Wren", number: 115)
    public static let bluebird = Bird("Sialia mexicana", "Western Bluebird", number: 122)
    public static let robin = Bird("Turdus migratorius", "American Robin", number: 125)
    public static let goldfinch = Bird("Spinus psaltria", "Lesser Goldfinch", number: 132)
    public static let junco = Bird("Junco hyemalis", "Dark-eyed Junco", number: 135)
    public static let towhee = Bird("Melozone crissalis", "California Towhee", number: 141)
}

/// Los Angeles as one regional set among the others, for a test that builds its own sets and wants a real one's id.
/// It is not the bundled pack and does not change when the bundled pack does: a test that reads the bundled pack, or
/// runs the app, uses `BundledPack`.
public enum LosAngelesSet {
    public static let id = "us-ca-la"
}
