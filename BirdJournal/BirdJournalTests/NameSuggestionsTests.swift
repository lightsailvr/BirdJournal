import Album
import Foundation
import Identification
import Pack
import SwiftUI
import Synchronization
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

    static let griffithPark = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)

    /// 9 November 2026 in Los Angeles: week 42 of BirdNET's 48.
    static func november() throws -> (date: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return (try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 41))), calendar)
    }

    @Test("the geomodel is read at the photo's place and week; with no place it isn't asked, and nothing is likely")
    func contextAtAPlace() throws {
        let (taken, calendar) = try Self.november()
        let model = SpyOccurrence()
        let here = NameableBirds.Context(heard: ["Calypte anna"], place: Self.griffithPark, takenAt: taken, occurrenceModel: model, calendar: calendar)
        #expect(here.heard == ["Calypte anna"])
        #expect(here.occurrence == ["Haemorhous mexicanus": 1, "Cyanocitta cristata": 0.01], "what the model says there")
        #expect(model.asked.withLock { $0 } == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: 42)], "the week the photo was taken in")

        let nowhere = NameableBirds.Context(heard: ["Calypte anna"], place: nil, takenAt: taken, occurrenceModel: model, calendar: calendar)
        #expect(nowhere == NameableBirds.Context(heard: ["Calypte anna"]))
        #expect(model.asked.withLock { $0.count } == 1, "no place, nothing to ask")

        struct Unreadable: SpeciesOccurrenceModel {
            func occurrence(in context: GeoContext) throws -> [String: Float] { throw CocoaError(.fileReadCorruptFile) }
        }
        let unread = NameableBirds.Context(heard: [], place: Self.griffithPark, takenAt: taken, occurrenceModel: Unreadable(), calendar: calendar)
        #expect(unread == .none, "a geomodel that can't be read leaves the names and the search")
    }

    @Test("the bundled geomodel at Griffith Park in November: the hummingbird that lives there is likely, and leads its search")
    func bundledGeomodel() throws {
        let (taken, calendar) = try Self.november()
        let pack = try SpeciesPack.bundled()
        let names = NameableBirds(fieldGuide: pack.species.map { .init(scientificName: $0.scientificName, commonName: $0.commonName) }, labels: try ONNXBirdModel.bundledLabels())
        let here = NameableBirds.Context(heard: [], place: Self.griffithPark, takenAt: taken, occurrenceModel: try ONNXGeoModel.bundled(), calendar: calendar)
        let occurrence = try #require(here.occurrence)

        // The geomodel's reading is broad, a range map more than a count: nearly every bird of the Los Angeles field guide
        // is likely here, and the twelve suggested are the commonest of the season.
        let suggested = names.search("", in: here)
        #expect(suggested.likely.count == 12)
        #expect(suggested.fieldGuide.isEmpty, "the likely birds stand in for the list by name")
        #expect(suggested.likely.allSatisfy { $0.isInFieldGuide })
        #expect(suggested.likely.contains { $0.commonName == "House Finch" } && suggested.likely.contains { $0.commonName == "Mourning Dove" }, "\(suggested.likely.map(\.commonName))")
        let readings = suggested.likely.compactMap { occurrence[$0.scientificName] }
        #expect(readings == readings.sorted(by: >) && readings.allSatisfy { $0 > 0.9 }, "the likeliest first: \(readings)")

        // A search is where the place tells: the hummingbirds that live in Los Angeles before the world's.
        let hummingbirds = names.search("hummingbird", in: here)
        #expect(hummingbirds.fieldGuide.map(\.commonName) == ["Anna's Hummingbird", "Allen's Hummingbird", "Black-chinned Hummingbird"])
        #expect(hummingbirds.others.prefix(2).map(\.commonName) == ["Rufous Hummingbird", "Costa's Hummingbird"], "western hummingbirds no field guide here describes")
        #expect(names.search("hummingbird").others.first?.commonName.hasPrefix("A") == true, "by name without a place")
    }

    @Test("the birds in the order they are listed, for a caller with no sections to draw")
    func orderedBirds() {
        let here = NameableBirds.Context(heard: ["Haemorhous mexicanus"], occurrence: Self.losAngeles)
        #expect(Self.names.search("", in: here).birds.map(\.commonName) == ["House Finch", "Black Phoebe", "Anna's Hummingbird", "Allen's Hummingbird"])
        #expect(
            Self.names.search("hummingbird", in: here).birds.map(\.commonName)
                == ["Anna's Hummingbird", "Allen's Hummingbird", "Black-chinned Hummingbird", "Amazilia Hummingbird", "Ruby-throated Hummingbird"]
        )
        #expect(Self.names.search("", in: .init(heard: ["Sayornis phoebe"])).birds.map(\.commonName) == ["Eastern Phoebe", "Allen's Hummingbird", "Anna's Hummingbird", "Black Phoebe", "House Finch", "Say's Phoebe"])
        #expect(Self.names.search("penguin", in: here).birds.isEmpty)
    }
}

// Issue #189: the suggestions on "Name this bird" as VoiceOver reaches them, in the serialized suite that walks the capture's
// other screens (they share a window and `-autoQuery`).
extension CaptureAccessibilityTests {
    /// A geomodel with one answer wherever it is asked.
    struct FixedOccurrence: SpeciesOccurrenceModel {
        var expected: [String: Float]
        func occurrence(in context: GeoContext) throws -> [String: Float] { expected }
    }

    static let griffithPark = LocationFix.fix(latitude: 34.1365, longitude: -118.2942, accuracy: 10, at: .now)
    static let geomodel = FixedOccurrence(expected: ["Haemorhous mexicanus": 0.99, "Sayornis nigricans": 0.95, "Calypte anna": 0.9, "Selasphorus sasin": 0.5, "Archilochus colubris": 0.001])

    /// A run in Griffith Park that heard a House Finch, quiet now, and then a Black Phoebe, still calling.
    static func runThatHeardTwo() async throws -> Screens.Harness {
        let harness = try Screens.Harness(location: [griffithPark])
        func heard(_ index: Int, _ scientific: String, _ common: String, last: Double) -> Candidate {
            Candidate(species: Species(index: index, scientificName: scientific, commonName: common, taxonomicClass: "Aves"), score: 0.8, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: last, admittedAt: Double(index))
        }
        harness.run.fakeStack = CandidateStack(candidates: [heard(0, "Haemorhous mexicanus", "House Finch", last: -120), heard(1, "Sayornis nigricans", "Black Phoebe", last: 1_000_000)])
        await harness.run.start()
        #expect(harness.run.coordinate != nil)
        return harness
    }

    @Test("Name this bird on a run: Heard this run with the bird calling first, then Likely here now, the likeliest first, and no list by name", arguments: Screens.sizes)
    func suggestions(typeSize: DynamicTypeSize) async throws {
        let harness = try await Self.runThatHeardTwo()
        let screen = NameBirdView(photo: Self.photo()) {}.environment(\.occurrenceModel, Self.geomodel)
        let labels = try await Screens.walk(screen, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("Likely here now") && labels.contains { $0.hasPrefix(typeSize == .large ? "Allen's Hummingbird, " : "Anna's Hummingbird, ") }
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Name this bird, suggestions")
        Screens.expectOneWordPerThing(labels, screen: "Name this bird, suggestions")
        Self.expectNoScore(labels, screen: "Name this bird, suggestions")
        let search = try #require(labels.firstIndex(of: "Search birds by name"), "\(labels)")
        let heard = try #require(labels.firstIndex(of: "Heard this run"), "\(labels)")
        let phoebe = try #require(labels.firstIndex { $0.hasPrefix("Black Phoebe, Los Angeles") }, "\(labels)")
        let finch = try #require(labels.firstIndex { $0.hasPrefix("House Finch, Los Angeles") }, "\(labels)")
        let likely = try #require(labels.firstIndex(of: "Likely here now"), "\(labels)")
        let annas = try #require(labels.firstIndex { $0.hasPrefix("Anna's Hummingbird, Los Angeles") }, "\(labels)")
        #expect(search < heard && heard < phoebe && phoebe < finch, "the bird calling now before the one heard earlier: \(labels)")
        #expect(finch < likely && likely < annas, "then the likely birds: \(labels)")
        // At the largest size the rows are a screen tall, and the lazy list has not laid the fourth out in the test's window.
        if typeSize == .large {
            let allens = try #require(labels.firstIndex { $0.hasPrefix("Allen's Hummingbird, Los Angeles") }, "\(labels)")
            #expect(annas < allens, "the likeliest first, not the first by name: \(labels)")
        }
        #expect(labels.count { $0.hasPrefix("House Finch, ") } == 1 && labels.count { $0.hasPrefix("Black Phoebe, ") } == 1, "a bird heard isn't listed again as likely: \(labels)")
        #expect(!labels.contains("In your field guides") && !labels.contains("All birds"), "\(labels)")
        #expect(labels.contains(NameBirdText.searchHint), "\(labels)")
        #expect(labels.contains("Choose the bird in your photo."), "\(labels)")
    }

    @Test("the run's birds are offered only while there is a run: calling now first while it listens, none once it is dismissed")
    func heardOnlyWithARun() async throws {
        let idle = try Screens.Harness()
        idle.run.fakeStack = CandidateStack(candidates: [Candidate(species: Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"), score: 0.8, windowsAboveThreshold: 2, firstHeardAt: 0, lastHeardAt: 1, admittedAt: 1)])
        #expect(idle.run.heardScientificNames.isEmpty, "no run")

        let harness = try await Self.runThatHeardTwo()
        #expect(harness.run.heardScientificNames == ["Sayornis nigricans", "Haemorhous mexicanus"], "the phoebe is calling; the finch was admitted first")
        await harness.run.stop()
        #expect(Set(harness.run.heardScientificNames) == ["Sayornis nigricans", "Haemorhous mexicanus"], "an ended run, as its review has it, still has its birds")
        harness.run.dismissEnded()
        #expect(harness.run.heardScientificNames.isEmpty)
    }

    @Test("Typing replaces the suggestions with the search, a likely bird before the others it matches", arguments: Screens.sizes)
    func suggestionsGiveWayToASearch(typeSize: DynamicTypeSize) async throws {
        let harness = try await Self.runThatHeardTwo()
        defer { UserDefaults.standard.removeObject(forKey: "autoQuery") }
        UserDefaults.standard.set("hummingbird", forKey: "autoQuery")
        let screen = NameBirdView(photo: Self.photo()) {}.environment(\.occurrenceModel, Self.geomodel)
        let labels = try await Screens.walk(screen, harness: harness, typeSize: typeSize, inStack: false) { labels in
            labels.contains("All birds")
        }
        await harness.run.stop()

        Screens.expectClean(labels, screen: "Name this bird, searched on a run")
        #expect(!labels.contains("Heard this run") && !labels.contains("Likely here now"), "\(labels)")
        let guides = try #require(labels.firstIndex(of: "In your field guides"), "\(labels)")
        let annas = try #require(labels.firstIndex { $0.hasPrefix("Anna's Hummingbird, ") }, "\(labels)")
        let allens = try #require(labels.firstIndex { $0.hasPrefix("Allen's Hummingbird, ") }, "\(labels)")
        #expect(guides < annas && annas < allens, "the likelier hummingbird first, not the first by name: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("House Finch, ") }, "only what matches: \(labels)")
    }
}
