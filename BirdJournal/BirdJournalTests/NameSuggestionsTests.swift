import Album
import Foundation
import Identification
import Testing
@testable import BirdJournal

// Issue #189 (of #185): what "Name this bird" lists before anything is typed, and how a search is ordered. One pure unit,
// `NameableBirds.search(_:in:)`, takes what was typed, or nothing, with the birds heard this run and the geomodel's reading
// at the capture's place and week; the lens's dictation (#194) orders its matches with the same one.
@Suite("Name suggestions")
struct NameSuggestionsTests {
    static func label(_ index: Int, _ scientific: String, _ common: String, class taxonomicClass: String = "Aves") -> Species {
        Species(index: index, scientificName: scientific, commonName: common, taxonomicClass: taxonomicClass)
    }

    /// Five birds of the field guide on the phone, three hummingbirds and a phoebe of the wider world, and a frog.
    static let names = NameableBirds(
        fieldGuide: [
            .init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird"),
            .init(scientificName: "Selasphorus sasin", commonName: "Allen's Hummingbird"),
            .init(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"),
            .init(scientificName: "Haemorhous mexicanus", commonName: "House Finch"),
            .init(scientificName: "Sayornis saya", commonName: "Say's Phoebe"),
        ],
        labels: [
            label(0, "Calypte anna", "Anna's Hummingbird"),
            label(1, "Selasphorus sasin", "Allen's Hummingbird"),
            label(2, "Sayornis nigricans", "Black Phoebe"),
            label(3, "Haemorhous mexicanus", "House Finch"),
            label(4, "Sayornis saya", "Say's Phoebe"),
            label(5, "Archilochus colubris", "Ruby-throated Hummingbird"),
            label(6, "Archilochus alexandri", "Black-chinned Hummingbird"),
            label(7, "Amazilis amazilia", "Amazilia Hummingbird"),
            label(8, "Sayornis phoebe", "Eastern Phoebe"),
            label(9, "Pseudacris regilla", "Pacific Chorus Frog", class: "Amphibia"),
        ]
    )

    @Test("with nothing typed, the birds heard this run come first, in the run's own order and each once")
    func heardThisRun() {
        // The run's order: calling now first. A frog can't be named, and neither can a bird the names don't know.
        let run = NameableBirds.Context(heard: ["Sayornis nigricans", "Pseudacris regilla", "Archilochus alexandri", "Haemorhous mexicanus", "Avis ignota", "Sayornis nigricans"])
        let results = Self.names.search("", in: run)
        #expect(results.heard.map(\.commonName) == ["Black Phoebe", "Black-chinned Hummingbird", "House Finch"], "a bird outside the field guides was heard too")
        #expect(results.heard.map(\.isInFieldGuide) == [true, false, true])
        #expect(Self.names.search("  ", in: run).heard.count == 3, "spaces are nothing typed")
        #expect(Self.names.search("", in: .none).heard.isEmpty, "no run, or one that has heard nothing")
    }

    /// The geomodel's reading somewhere in Los Angeles: the finch and the two resident hummingbirds are likely, Say's Phoebe
    /// is below the floor at which identification admits a bird, and the Ruby-throated Hummingbird isn't expected at all.
    static let losAngeles: [String: Float] = [
        "Haemorhous mexicanus": 0.99, "Sayornis nigricans": 0.97, "Calypte anna": 0.92, "Selasphorus sasin": 0.4,
        "Archilochus alexandri": 0.5, "Sayornis saya": 0.02, "Archilochus colubris": 0.001, "Pseudacris regilla": 0.9,
    ]

    @Test("then the field guides' birds the geomodel finds likely at the place and week, the likeliest first")
    func likelyHereNow() {
        let results = Self.names.search("", in: .init(heard: ["Haemorhous mexicanus"], occurrence: Self.losAngeles))
        #expect(results.heard.map(\.commonName) == ["House Finch"])
        #expect(
            results.likely.map(\.commonName) == ["Black Phoebe", "Anna's Hummingbird", "Allen's Hummingbird"],
            "not the bird heard again, not one below the floor, and not the Black-chinned Hummingbird, which no field guide here describes"
        )
        #expect(results.fieldGuide.isEmpty && results.others.isEmpty, "the suggestions stand in for the list by name")
        #expect(!results.isEmpty)

        #expect(Self.names.search("", in: .init(occurrence: Self.losAngeles), likelyLimit: 2).likely.map(\.commonName) == ["House Finch", "Black Phoebe"], "the most likely, not all of them")
        let level = Self.names.search("", in: .init(occurrence: ["Sayornis nigricans": 0.5, "Calypte anna": 0.5, "Selasphorus sasin": 0.5]))
        #expect(level.likely.map(\.commonName) == ["Allen's Hummingbird", "Anna's Hummingbird", "Black Phoebe"], "equally likely birds by name")
        #expect(Self.names.search("", in: .init(occurrence: ["Sayornis saya": NameableBirds.likelyFloor])).likely.map(\.commonName) == ["Say's Phoebe"], "the floor itself is likely")
    }

    @Test("without a place no bird is called likely: the field guides' birds are listed by name instead, under the birds heard")
    func noPlace() {
        let results = Self.names.search("", in: .init(heard: ["Sayornis nigricans"]))
        #expect(results.heard.map(\.commonName) == ["Black Phoebe"])
        #expect(results.likely.isEmpty)
        #expect(results.fieldGuide.map(\.commonName) == ["Allen's Hummingbird", "Anna's Hummingbird", "House Finch", "Say's Phoebe"], "by name, without the bird heard again")
        #expect(results.others.isEmpty && results.moreOthers == 0, "the rest are found by typing")

        // A place where the geomodel expects none of the field guides' birds reads the same.
        let far = Self.names.search("", in: .init(occurrence: ["Archilochus colubris": 0.9, "Sayornis saya": 0.01]))
        #expect(far.likely.isEmpty)
        #expect(far.fieldGuide.count == 5)
    }

    @Test("typing replaces the suggestions with the search, and among its matches a bird heard this run or likely here comes before one that is neither")
    func rankedSearch() {
        // Under the word-start rule every match is as good as another, so what the run and the place know orders them all.
        let here = NameableBirds.Context(heard: ["Sayornis saya"], occurrence: Self.losAngeles)
        let phoebes = Self.names.search("phoebe", in: here)
        #expect(phoebes.heard.isEmpty && phoebes.likely.isEmpty, "no suggestions once something is typed")
        #expect(phoebes.fieldGuide.map(\.commonName) == ["Say's Phoebe", "Black Phoebe"], "the one heard first, though the place makes it unlikely")
        #expect(phoebes.others.map(\.commonName) == ["Eastern Phoebe"])

        let hummingbirds = Self.names.search("hummingbird", in: here)
        #expect(hummingbirds.fieldGuide.map(\.commonName) == ["Anna's Hummingbird", "Allen's Hummingbird"], "the likelier first")
        #expect(
            hummingbirds.others.map(\.commonName) == ["Black-chinned Hummingbird", "Amazilia Hummingbird", "Ruby-throated Hummingbird"],
            "the one likely here, then the rest by name: far below the floor is not likely"
        )
        let capped = Self.names.search("hummingbird", in: here, otherLimit: 1)
        #expect(capped.others.map(\.commonName) == ["Black-chinned Hummingbird"], "the likely bird is among the first listed")
        #expect(capped.moreOthers == 2)

        // Several heard: in the run's order, whatever the place says of them.
        let run = NameableBirds.Context(heard: ["Archilochus colubris", "Calypte anna", "Selasphorus sasin"], occurrence: ["Selasphorus sasin": 0.9, "Calypte anna": 0.1, "Amazilis amazilia": 0.8])
        let heard = Self.names.search("hummingbird", in: run)
        #expect(heard.fieldGuide.map(\.commonName) == ["Anna's Hummingbird", "Allen's Hummingbird"])
        #expect(heard.others.map(\.commonName) == ["Ruby-throated Hummingbird", "Amazilia Hummingbird", "Black-chinned Hummingbird"])

        // With no run and no place, by name as ever.
        let plain = Self.names.search("hummingbird")
        #expect(plain.fieldGuide.map(\.commonName) == ["Allen's Hummingbird", "Anna's Hummingbird"])
        #expect(plain.others.map(\.commonName) == ["Amazilia Hummingbird", "Black-chinned Hummingbird", "Ruby-throated Hummingbird"])
    }
}
