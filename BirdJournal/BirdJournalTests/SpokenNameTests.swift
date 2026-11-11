import Identification
import Testing
@testable import BirdJournal

// Issue #194 (of #185): a bird's name said to the glasses, matched against the birds a photo can be named as. One pure
// function, `NameableBirds.spoken(_:in:limit:)`: it forgives what a recogniser does to bird names (a dropped apostrophe,
// a word split or joined, a near-miss, a homophone) and orders what it finds by how close it is and then as "Name this
// bird" orders a search: heard this run, likely here, the field guides, all birds.
@Suite("Spoken bird names")
struct SpokenNameTests {
    static func label(_ index: Int, _ scientific: String, _ common: String, class taxonomicClass: String = "Aves") -> Species {
        Species(index: index, scientificName: scientific, commonName: common, taxonomicClass: taxonomicClass)
    }

    /// Nine birds of the field guide on the phone, four of the wider world, and a frog.
    static let names = NameableBirds(
        fieldGuide: [
            .init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird"),
            .init(scientificName: "Selasphorus sasin", commonName: "Allen's Hummingbird"),
            .init(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"),
            .init(scientificName: "Haemorhous mexicanus", commonName: "House Finch"),
            .init(scientificName: "Sayornis saya", commonName: "Say's Phoebe"),
            .init(scientificName: "Zenaida macroura", commonName: "Mourning Dove"),
            .init(scientificName: "Melozone crissalis", commonName: "California Towhee"),
            .init(scientificName: "Psaltriparus minimus", commonName: "Bushtit"),
            .init(scientificName: "Buteo jamaicensis", commonName: "Red-tailed Hawk"),
        ],
        labels: [
            label(0, "Calypte anna", "Anna's Hummingbird"),
            label(1, "Selasphorus sasin", "Allen's Hummingbird"),
            label(2, "Sayornis nigricans", "Black Phoebe"),
            label(3, "Haemorhous mexicanus", "House Finch"),
            label(4, "Sayornis saya", "Say's Phoebe"),
            label(5, "Zenaida macroura", "Mourning Dove"),
            label(6, "Melozone crissalis", "California Towhee"),
            label(7, "Psaltriparus minimus", "Bushtit"),
            label(8, "Buteo jamaicensis", "Red-tailed Hawk"),
            label(9, "Archilochus colubris", "Ruby-throated Hummingbird"),
            label(10, "Archilochus alexandri", "Black-chinned Hummingbird"),
            label(11, "Amazilis amazilia", "Amazilia Hummingbird"),
            label(12, "Sayornis phoebe", "Eastern Phoebe"),
            label(13, "Pseudacris regilla", "Pacific Chorus Frog", class: "Amphibia"),
        ]
    )

    static func said(_ words: String, in context: NameableBirds.Context = .none, limit: Int = 3) -> [String] {
        names.spoken(words, in: context, limit: limit).map(\.commonName)
    }

    @Test("the name as a recogniser writes it finds its bird: no apostrophe, a word split in two, capitals and a full stop", arguments: [
        ("annas humming bird", "Anna's Hummingbird"),
        ("Anna's Hummingbird.", "Anna's Hummingbird"),
        ("Black Phoebe", "Black Phoebe"),
        ("bush tit", "Bushtit"),
        ("red tailed hawk", "Red-tailed Hawk"),
        ("says phoebe", "Say's Phoebe"),
    ])
    func asWritten(_ said: String, _ bird: String) {
        #expect(Self.said(said).first == bird)
    }

    @Test("words run together find it too", arguments: [
        ("blackphoebe", "Black Phoebe"),
        ("housefinch", "House Finch"),
        ("redtailed hawk", "Red-tailed Hawk"),
    ])
    func joined(_ said: String, _ bird: String) {
        #expect(Self.said(said) == [bird])
    }

    @Test("a near-miss or a word that only sounds the same finds it", arguments: [
        ("black feeby", "Black Phoebe"),
        ("morning dove", "Mourning Dove"),
        ("allen hummingbird", "Allen's Hummingbird"),
        ("california tohee", "California Towhee"),
        ("house finsh", "House Finch"),
        ("red tail hawk", "Red-tailed Hawk"),
    ])
    func nearMiss(_ said: String, _ bird: String) {
        #expect(Self.said(said).first == bird)
    }

    @Test("what people say around the name is dropped", arguments: [
        ("it's a black phoebe", "Black Phoebe"),
        ("um the house finch", "House Finch"),
        ("I think that's an Anna's hummingbird", "Anna's Hummingbird"),
    ])
    func filler(_ said: String, _ bird: String) {
        #expect(Self.said(said).first == bird)
    }

    /// The geomodel's reading somewhere in Los Angeles.
    static let losAngeles: [String: Float] = [
        "Haemorhous mexicanus": 0.99, "Sayornis nigricans": 0.97, "Calypte anna": 0.92, "Selasphorus sasin": 0.4,
        "Archilochus alexandri": 0.5, "Sayornis saya": 0.02, "Archilochus colubris": 0.001,
    ]

    @Test("part of a name finds every bird with it, in the naming sheet's order: heard this run, likely here, the field guides, all birds")
    func partOfAName() {
        // Nothing known: the field guides' birds by name, then the others by name.
        #expect(Self.said("hummingbird", limit: 9) == ["Allen's Hummingbird", "Anna's Hummingbird", "Amazilia Hummingbird", "Black-chinned Hummingbird", "Ruby-throated Hummingbird"])
        // The bird heard this run first, though no field guide has it; then the likely ones, the likeliest first.
        let run = NameableBirds.Context(heard: ["Archilochus colubris"], occurrence: Self.losAngeles)
        #expect(Self.said("hummingbird", in: run, limit: 9) == ["Ruby-throated Hummingbird", "Anna's Hummingbird", "Black-chinned Hummingbird", "Allen's Hummingbird", "Amazilia Hummingbird"])
        #expect(Self.said("hummingbird", in: run) == ["Ruby-throated Hummingbird", "Anna's Hummingbird", "Black-chinned Hummingbird"], "the top three")
        #expect(Self.said("phoebe", in: .init(occurrence: Self.losAngeles)) == ["Black Phoebe", "Say's Phoebe", "Eastern Phoebe"], "likely, then the field guide's, then the rest")
        #expect(Self.said("ruby throated") == ["Ruby-throated Hummingbird"], "a run of a name's words, of a bird no field guide has")
    }

    @Test("the bird that was named comes before a bird heard this run that is only close, and a whole name before a part of one")
    func closenessFirst() {
        let annaCalling = NameableBirds.Context(heard: ["Calypte anna"], occurrence: Self.losAngeles)
        #expect(Self.said("allens hummingbird", in: annaCalling).first == "Allen's Hummingbird")
        #expect(Self.said("alans hummingbird", in: annaCalling).first == "Allen's Hummingbird", "it sounds the same; Anna's is two letters off")
        #expect(Self.said("eastern phoebe", in: .init(heard: ["Sayornis nigricans"])) == ["Eastern Phoebe"], "the other phoebes are not what was said")
    }

    /// The field guide's two hummingbirds and a hawk among birds of the wider world whose names lie near them: what the
    /// ten thousand names did to the first cut of this, seen on the mock lens.
    static let world = NameableBirds(
        fieldGuide: [
            .init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird"),
            .init(scientificName: "Selasphorus sasin", commonName: "Allen's Hummingbird"),
            .init(scientificName: "Accipiter cooperii", commonName: "Cooper's Hawk"),
        ],
        labels: [
            label(0, "Calypte anna", "Anna's Hummingbird"),
            label(1, "Selasphorus sasin", "Allen's Hummingbird"),
            label(2, "Accipiter cooperii", "Cooper's Hawk"),
            label(3, "Mellisuga helenae", "Bee Hummingbird"),
            label(4, "Myrmelastes humaythae", "Humaita Antbird"),
            label(5, "Rhodopis vesper", "Oasis Hummingbird"),
            label(6, "Amazilis amazilia", "Amazilia Hummingbird"),
        ]
    )

    @Test("a word of a name finds the birds that have that word before any bird whose whole name is only near it")
    func aWordBeforeANearName() {
        // "Bee Hummingbird" is two sounds from "hummingbird" and "Humaita Antbird" three: neither is nearer than the
        // hummingbirds themselves, and the antbird is no hummingbird at all.
        let found = Self.world.spoken("hummingbird", limit: 9).map(\.commonName)
        #expect(found.prefix(5) == ["Allen's Hummingbird", "Anna's Hummingbird", "Amazilia Hummingbird", "Bee Hummingbird", "Oasis Hummingbird"])
        #expect(found.count == 5 || found.last == "Humaita Antbird")
    }

    @Test("among names that are only near what was said, a bird heard this run, likely here or in the field guides comes before a bird of the wider world that is a sound nearer")
    func nearNamesByWhereTheBirdStands() {
        // "anas" is one sound from "oasis" and two from "allens".
        #expect(Self.world.spoken("annas humming bird").map(\.commonName) == ["Anna's Hummingbird", "Allen's Hummingbird", "Oasis Hummingbird"])
        #expect(Self.world.spoken("oasas hummingbird").map(\.commonName).first == "Oasis Hummingbird", "it sounds the same, which nothing near beats")
        // Said badly, a sound from each of two birds: the field guide's.
        #expect(Self.world.spoken("atas hummingbird").map(\.commonName).first == "Anna's Hummingbird")
        let heard = NameableBirds.Context(heard: ["Rhodopis vesper"])
        #expect(Self.world.spoken("atas hummingbird", in: heard).map(\.commonName).first == "Oasis Hummingbird", "heard this run")
    }

    @Test("a possessive without its s is the name as written: the bird that was named, before a bird heard this run that is only near", arguments: [
        ("allen hummingbird", "Allen's Hummingbird", "Calypte anna"),
        ("anna hummingbird", "Anna's Hummingbird", "Selasphorus sasin"),
        ("cooper hawk", "Cooper's Hawk", "Calypte anna"),
        ("coopers hawk", "Cooper's Hawk", "Calypte anna"),
    ])
    func possessives(_ said: String, _ bird: String, _ heard: String) {
        #expect(Self.world.spoken(said, in: .init(heard: [heard])).first?.commonName == bird)
    }

    @Test("nothing said, only filler, or no bird by that name finds nothing; a frog cannot be named", arguments: ["", "   ", "the", "um", "flibbertigibbet", "pacific chorus frog", "xy"])
    func nothing(_ said: String) {
        #expect(Self.said(said).isEmpty)
    }

    @Test("a short word is not stretched into another: a wren is no raven, and a dove no dive bar")
    func shortWords() {
        let birds = NameableBirds(fieldGuide: [], labels: [
            Self.label(0, "Corvus corax", "Common Raven"), Self.label(1, "Troglodytes aedon", "House Wren"), Self.label(2, "Rallus limicola", "Virginia Rail"),
        ])
        #expect(birds.spoken("wren").map(\.commonName) == ["House Wren"])
        #expect(birds.spoken("ren").map(\.commonName) == ["House Wren"], "as it sounds")
        #expect(birds.spoken("rail").map(\.commonName) == ["Virginia Rail"])
    }

    @Test("the pack's spelling and BirdNET's both find a bird they name differently")
    func bothSpellings() {
        let birds = NameableBirds(
            fieldGuide: [.init(scientificName: "Aphelocoma californica", commonName: "California Scrub-Jay")],
            labels: [Self.label(0, "Aphelocoma californica", "Western Scrub Jay")]
        )
        #expect(birds.spoken("california scrub jay").map(\.scientificName) == ["Aphelocoma californica"])
        #expect(birds.spoken("western scrub jay").map(\.scientificName) == ["Aphelocoma californica"])
        #expect(birds.spoken("scrub jay").count == 1, "one bird, once")
    }

    @Test("over every bird BirdNET knows, a name as a recogniser writes it still finds its bird first, and soon enough for a wearer waiting on the lens")
    func bundledNames() throws {
        let birds = try NameableBirds.load(fieldGuide: [])
        let clock = ContinuousClock()
        var found: [NameableBird] = []
        let took = clock.measure { found = birds.spoken("annas humming bird") }
        #expect(found.first?.scientificName == "Calypte anna")
        #expect(birds.spoken("black feeby").first?.scientificName == "Sayornis nigricans")
        #expect(birds.spoken("morning dove").first?.scientificName == "Zenaida macroura")
        // A debug build on a loaded Mac; a phone does it in a fraction of this.
        #expect(took < .seconds(5), "\(took)")
    }
}
