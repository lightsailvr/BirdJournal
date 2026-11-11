import Album
import Foundation
import Identification
import Testing
@testable import BirdJournal

// Issue #186: naming a seen bird. The search is over the birds of the field-guide downloads on the phone, which come first,
// and then every other bird the BirdNET label list knows by name.
@Suite("Nameable birds")
struct NameableBirdsTests {
    static func label(_ index: Int, _ scientific: String, _ common: String, class taxonomicClass: String = "Aves") -> Species {
        Species(index: index, scientificName: scientific, commonName: common, taxonomicClass: taxonomicClass)
    }

    static let labels = [
        label(0, "Calypte anna", "Anna's Hummingbird"),
        label(1, "Selasphorus sasin", "Allen's Hummingbird"),
        label(2, "Archilochus colubris", "Ruby-throated Hummingbird"),
        label(3, "Sayornis nigricans", "Black Phoebe"),
        label(4, "Sayornis phoebe", "Eastern Phoebe"),
        label(5, "Pseudacris regilla", "Pacific Chorus Frog", class: "Amphibia"),
        label(6, "Phaethornis superciliosus", "Long-tailed Hermit"),
    ]

    /// Two field guides on the phone: both describe Anna's Hummingbird, and the second has a bird BirdNET doesn't list.
    static let names = NameableBirds(
        fieldGuide: [
            .init(scientificName: "Sayornis nigricans", commonName: "Black Phoebe"),
            .init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird"),
            .init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird"),
            .init(scientificName: "Avis ignota", commonName: "Unlisted Warbler"),
        ],
        labels: labels
    )

    @Test("field-guide birds come first, each once and by name, and every other bird BirdNET knows below them")
    func fieldGuideFirst() {
        let results = Self.names.search("hummingbird")
        #expect(results.fieldGuide.map(\.commonName) == ["Anna's Hummingbird"])
        #expect(results.others.map(\.commonName) == ["Allen's Hummingbird", "Ruby-throated Hummingbird"], "by name, without the field guide's bird again")
        #expect(!results.isEmpty)
    }

    @Test("a search matches word starts of the common or the scientific name, whatever the case or the accents")
    func commonAndScientificNames() {
        #expect(Self.names.search("phoe").fieldGuide.map(\.commonName) == ["Black Phoebe"])
        #expect(Self.names.search("phoe").others.map(\.commonName) == ["Eastern Phoebe"])
        #expect(Self.names.search("SAYORNIS").fieldGuide.map(\.commonName) == ["Black Phoebe"], "the scientific name")
        #expect(Self.names.search("selas sas").others.map(\.commonName) == ["Allen's Hummingbird"])
        #expect(Self.names.search("annas").fieldGuide.isEmpty, "a dropped apostrophe is another word; forgiving it is the dictation's work (#194)")
        #expect(Self.names.search("hermit").others.map(\.scientificName) == ["Phaethornis superciliosus"])
        #expect(Self.names.search("hoebe").isEmpty, "not inside a word")
    }

    @Test("a search nothing matches is empty, and says so")
    func noMatch() {
        let results = Self.names.search("penguin")
        #expect(results.fieldGuide.isEmpty && results.others.isEmpty)
        #expect(results.isEmpty)
        #expect(results.moreOthers == 0)
    }

    @Test("a sighting is written under the label BirdNET uses for the bird, so a seen one and a heard one share a patch")
    func speciesIDs() {
        let phoebe = Self.names.search("black phoebe").fieldGuide.first
        #expect(phoebe?.speciesID == "Sayornis nigricans_Black Phoebe")
        #expect(phoebe?.speciesID == Self.labels[3].birdnetLabel)
        #expect(Self.names.search("allen").others.first?.speciesID == "Selasphorus sasin_Allen's Hummingbird")
        let unlisted = Self.names.search("unlisted").fieldGuide.first
        #expect(unlisted?.speciesID == "Avis ignota_Unlisted Warbler", "a field-guide bird BirdNET doesn't list still has a label of the same shape")
        #expect(unlisted?.isInFieldGuide == true)
        #expect(Self.names.search("allen").others.first?.isInFieldGuide == false)
    }

    @Test("only birds can be named: BirdNET's frogs, insects and mammals are left out")
    func birdsOnly() {
        #expect(Self.names.search("frog").isEmpty)
        #expect(Self.names.search("pacific").isEmpty)
    }

    @Test("before anything is typed the field guides' birds are listed by name, and no other: there are thousands")
    func emptyQuery() {
        let results = Self.names.search("  ")
        #expect(results.fieldGuide.map(\.commonName) == ["Anna's Hummingbird", "Black Phoebe", "Unlisted Warbler"])
        #expect(results.others.isEmpty)
        #expect(results.moreOthers == 0)
        #expect(!results.isEmpty)
    }

    @Test("a broad search lists the first other birds and counts the rest")
    func othersAreCapped() {
        let results = Self.names.search("h", otherLimit: 1)
        #expect(results.others.map(\.commonName) == ["Allen's Hummingbird"])
        #expect(results.moreOthers == 2, "the Ruby-throated Hummingbird and the Long-tailed Hermit")
    }

    @Test("a bird is found again by its label, as a sighting stores it")
    func lookUp() {
        #expect(Self.names.bird(scientificName: "Sayornis nigricans")?.commonName == "Black Phoebe")
        #expect(Self.names.bird(scientificName: "Selasphorus sasin")?.speciesID == "Selasphorus sasin_Allen's Hummingbird")
        #expect(Self.names.bird(scientificName: "Pseudacris regilla") == nil)
    }

    @Test("the label list in the app has thousands of birds, and the bundled field guide's birds are among the names")
    func bundledLabels() throws {
        let labels = try ONNXBirdModel.bundledLabels()
        let names = NameableBirds(fieldGuide: [.init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird")], labels: labels)
        let results = names.search("anna's hummingbird")
        #expect(results.fieldGuide.map(\.speciesID) == ["Calypte anna_Anna's Hummingbird"])
        #expect(names.search("hummingbird").others.count + names.search("hummingbird").moreOthers > 50, "hummingbirds of the world")
    }
}

// Issue #186: what "Name this bird" and the run's "Seen this run" rows say, apart from the views.
@Suite("Name this bird's words")
@MainActor
struct NameBirdTextTests {
    static let losAngeles = CardPlacement.numbered(setID: "us-ca-la", setName: "Los Angeles", edition: "Citrus edition", number: 21, total: 160)

    @Test("a field guide's bird says its set and New to you here, or how often it was seen here; any other bird is marked by its placement")
    func status() {
        #expect(NameBirdText.status(placement: Self.losAngeles, seenHere: 0, isInFieldGuide: true) == ["Los Angeles", "New to you here"])
        #expect(NameBirdText.status(placement: Self.losAngeles, seenHere: 1, isInFieldGuide: true) == ["Los Angeles", "Seen once here"])
        #expect(NameBirdText.status(placement: Self.losAngeles, seenHere: 2, isInFieldGuide: true) == ["Los Angeles", "Seen 2 times here"])
        #expect(NameBirdText.status(placement: .uncharted, seenHere: 0, isInFieldGuide: true) == ["Uncharted", "New to you here"], "a field guide's bird far from its set")
        #expect(NameBirdText.status(placement: .uncharted, seenHere: 0, isInFieldGuide: false) == ["Uncharted"])
        #expect(NameBirdText.status(placement: .uncharted, seenHere: 3, isInFieldGuide: false) == ["Uncharted", "Seen 3 times here"])
        #expect(NameBirdText.line(["Los Angeles", "New to you here"]) == "Los Angeles · New to you here")
        #expect(NameBirdText.spoken(name: "Black Phoebe", status: ["Los Angeles", "New to you here"]) == "Black Phoebe, Los Angeles, New to you here", "no middle dot for VoiceOver")
    }

    @Test("the pinned button sews a patch for a bird new here and adds a sighting otherwise, and the line under it says which bird")
    func add() {
        #expect(NameBirdText.addTitle(seenHere: 0) == "Add and sew patch")
        #expect(NameBirdText.addTitle(seenHere: 4) == "Add sighting")
        #expect(NameBirdText.addTitle(seenHere: nil) == "Add sighting", "before a bird is chosen")
        #expect(NameBirdText.addNote(name: nil, seenHere: 0) == "Choose the bird in your photo.")
        #expect(NameBirdText.addNote(name: "Black Phoebe", seenHere: 0) == "Black Phoebe, new to you here.")
        #expect(NameBirdText.addNote(name: "Black Phoebe", seenHere: 1) == "Black Phoebe, seen once here.")
        #expect(NameBirdText.more(0) == nil)
        #expect(NameBirdText.more(212) == "And 212 more. Keep typing to narrow them down.")
    }

    // Review of #185, S2: CONTEXT.md's Add entry avoids "save" for an add.
    @Test("an add that fails says the sighting couldn't be added, and that the photo is kept: an add is never saved")
    func addFailedSaysAdded() {
        #expect(NameBirdText.addFailed == "The sighting couldn't be added. Your photo is kept. Try again.")
        #expect(!NameBirdText.addFailed.localizedCaseInsensitiveContains("save"))
    }

    @Test("a seen bird's row says Seen, your photo, and New patch or its patch's count")
    func seenRow() {
        #expect(NameBirdText.line(NameBirdText.seenRow(sewedPatch: true, count: 1)) == "Seen · your photo · New patch")
        #expect(NameBirdText.line(NameBirdText.seenRow(sewedPatch: false, count: 3)) == "Seen 3 times here · your photo")
        #expect(NameBirdText.sentence(["Allen's Hummingbird"] + NameBirdText.seenRow(sewedPatch: true, count: 1)) == "Allen's Hummingbird, Seen, your photo, New patch")
    }

    @Test("the photo's time reads Today on the day it was taken, and its place is the run's, or not recorded")
    func photoFacts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_US")
        let taken = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 41)))
        #expect(NameBirdText.taken(taken, now: taken.addingTimeInterval(120), calendar: calendar, locale: locale).replacing("\u{202F}", with: " ") == "Today, 9:41 AM")
        let nextDay = NameBirdText.taken(taken, now: taken.addingTimeInterval(86_400), calendar: calendar, locale: locale).replacing("\u{202F}", with: " ")
        #expect(nextDay.hasPrefix("Nov 9, 2026") && nextDay.hasSuffix("9:41 AM"), "\(nextDay)")

        let griffith = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)
        #expect(NameBirdText.place(location: griffith, name: "Griffith Park, Los Angeles") == "Near Griffith Park, Los Angeles")
        #expect(NameBirdText.place(location: griffith, name: nil).hasPrefix("Near 34"))
        #expect(NameBirdText.place(location: nil, name: nil) == "Place not recorded")
    }

    @Test("the camera's pill says the run is still listening with its clock, that it is paused, or that it has stopped")
    @MainActor
    func pill() {
        #expect(CaptureCameraText.listening(for: .listening)?.text == "Still listening")
        #expect(CaptureCameraText.listening(for: .listening)?.showsClock == true)
        #expect(CaptureCameraText.listening(for: .paused(.glassesOff))?.text == "Listening paused")
        #expect(CaptureCameraText.listening(for: .interrupted)?.showsClock == false)
        #expect(CaptureCameraText.listening(for: .ended(.stopped))?.text == "Listening stopped")
        #expect(CaptureCameraText.listening(for: .idle) == nil, "no run, no pill")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CaptureCameraText.spokenClock(from: start, to: start.addingTimeInterval(771)) == "12 minutes 51 seconds")
        #expect(CaptureCameraText.spokenClock(from: start, to: start.addingTimeInterval(61)) == "1 minute 1 second")
    }
}
