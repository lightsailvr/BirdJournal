import Album
import Foundation
import Pack
import SwiftData
import Testing
@testable import BirdJournal

/// Captions (issue #56): written once after an add by a writer behind `CaptionWriter`, from the fact sheet and the
/// moment only, with no place for a threatened species, and the lore's tagline in their place when the writer can't.
@Suite("Captions")
@MainActor
struct CaptionTests {
    /// Records every request and answers with a fixed line, or throws.
    final class FakeWriter: CaptionWriter, @unchecked Sendable {
        let version = "fake@1"
        var isAvailable = true
        var reply: String = "At dawn by the water, the dark sentinel was heard."
        var fails = false
        private(set) var requests: [CaptionRequest] = []

        func caption(for request: CaptionRequest) async throws -> String {
            requests.append(request)
            if fails { throw CocoaError(.featureUnsupported) }
            return reply
        }
    }

    static let phoebe = Captioner.Species(
        commonName: "Black Phoebe",
        facts: ["It feeds mostly on insects and other invertebrates.", "The black phoebe hunts from a low perch."],
        isThreatened: false
    )
    static let pasadena = Coordinate(latitude: 34.1478, longitude: -118.1445, accuracy: 10)

    /// A Los Angeles calendar, so the hour of a sighting is fixed whatever zone the test runs in.
    static var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    static func fixture(species: Captioner.Species? = phoebe, location: Coordinate? = pasadena, method: SightingMethod = .heard) throws -> (ModelContainer, Sighting, FakeWriter, Captioner) {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        // 2026-12-02 07:30 in Los Angeles.
        let date = try Date("2026-12-02T15:30:00Z", strategy: .iso8601)
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: date, location: location, soundConfidence: 0.8, source: .phone, method: method)
        sighting.note = "Private note: by my neighbour's gate."
        container.mainContext.insert(sighting)
        try container.mainContext.save()
        let writer = FakeWriter()
        let captioner = Captioner(writer: writer, species: { $0 == "Sayornis nigricans" ? species : nil }, placeLabel: { _ in "Pasadena" })
        captioner.calendar = losAngeles
        return (container, sighting, writer, captioner)
    }

    @Test("the prompt carries only the species' name, its fact sheet and the moment")
    func promptIsTheFactSheetAndTheMoment() async throws {
        let (container, sighting, writer, captioner) = try Self.fixture()
        _ = container
        await captioner.caption(sighting)

        let request = try #require(writer.requests.first)
        #expect(request == CaptionRequest(
            commonName: "Black Phoebe",
            facts: Self.phoebe.facts,
            moment: CaptionMoment(date: sighting.confirmedAt, latitude: 34.1478, method: .heard, place: "Pasadena", isThreatened: false, calendar: Self.losAngeles)
        ))
        #expect(request.moment.season == .winter && request.moment.timeOfDay == .earlyMorning)
        #expect(request.prompt == """
            Species: Black Phoebe

            Fact sheet:
            - It feeds mostly on insects and other invertebrates.
            - The black phoebe hunts from a low perch.

            The moment:
            - season: winter
            - time of day: early morning
            - the birder heard it
            - place: Pasadena
            """)
        #expect(!request.prompt.contains("neighbour") && !request.prompt.contains("34.1") && !request.prompt.contains("118"), "no note, no coordinate")
    }

    @Test("a threatened species, or one whose pack doesn't say, gets no place")
    func noPlaceForThreatenedSpecies() async throws {
        for threatened in [true, nil] as [Bool?] {
            var species = Self.phoebe
            species.isThreatened = threatened
            let (container, sighting, writer, captioner) = try Self.fixture(species: species)
            _ = container
            await captioner.caption(sighting)
            let request = try #require(writer.requests.first)
            #expect(request.moment.place == nil)
            #expect(!request.prompt.contains("Pasadena") && !request.prompt.contains("place:"))
        }
    }

    @Test("a caption is stored once with its writer's version and never written again, as when the card reopens")
    func storedOnce() async throws {
        let (container, sighting, writer, captioner) = try Self.fixture()
        await captioner.caption(sighting)
        #expect(sighting.caption == CardCaption(text: "At dawn by the water, the dark sentinel was heard.", generatorVersion: "fake@1"))

        writer.reply = "Another line."
        await captioner.caption(sighting)
        #expect(writer.requests.count == 1)
        let stored = try #require(try container.mainContext.fetch(FetchDescriptor<Sighting>()).first)
        #expect(stored.caption?.text == "At dawn by the water, the dark sentinel was heard.", "saved, and unchanged")
    }

    @Test("without the model, or when it fails or runs long, the sighting keeps no caption and the card shows the lore's tagline")
    func taglineFallback() async throws {
        let (container, sighting, writer, captioner) = try Self.fixture()
        _ = container
        writer.isAvailable = false
        await captioner.caption(sighting)
        #expect(writer.requests.isEmpty && sighting.caption == nil)

        writer.isAvailable = true
        writer.fails = true
        await captioner.caption(sighting)
        #expect(sighting.caption == nil)

        writer.fails = false
        writer.reply = Array(repeating: "word", count: 19).joined(separator: " ")
        await captioner.caption(sighting)
        #expect(sighting.caption == nil, "nineteen words is over the limit")

        #expect(CaptionText.front(caption: sighting.caption, tagline: "Keeper of the low perch.") == "Keeper of the low perch.")
        #expect(CaptionText.front(caption: CardCaption(text: "A caption.", generatorVersion: "fake@1"), tagline: "Keeper of the low perch.") == "A caption.")
        #expect(CaptionText.front(caption: nil, tagline: nil) == nil)
    }

    @Test("a species no pack has a fact sheet for gets no caption")
    func noFactSheet() async throws {
        let (container, sighting, writer, captioner) = try Self.fixture(species: nil)
        _ = container
        await captioner.caption(sighting)
        #expect(writer.requests.isEmpty && sighting.caption == nil)
    }

    @Test("the season follows the hemisphere, and is left out without a location")
    func seasons() {
        #expect(CaptionMoment.season(month: 12, southern: false) == .winter)
        #expect(CaptionMoment.season(month: 12, southern: true) == .summer)
        #expect(CaptionMoment.season(month: 4, southern: true) == .autumn)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CaptionMoment(date: date, latitude: nil, method: .seen, place: nil, isThreatened: false).season == nil)
    }

    @Test("an add from the run ledger is captioned after the sighting is written")
    func addIsCaptioned() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let folder = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = RunSightings(recorder: SightingRecorder(container: album, frames: FrameStore(directory: folder)))
        let writer = FakeWriter()
        let finch = Captioner.Species(commonName: "House Finch", facts: ["It feeds mostly on seeds."], isThreatened: false)
        ledger.captioner = Captioner(writer: writer, species: { _ in finch }, placeLabel: { _ in nil })

        let addition = try ledger.add(RunSightingsTests.candidate(score: 0.6), confirmedAt: .now, location: nil, frame: nil, source: .phone)
        let sighting = try #require(try album.mainContext.fetch(FetchDescriptor<Sighting>()).first { $0.identifier == addition.identifier })
        for _ in 0..<100 where sighting.caption == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sighting.caption?.generatorVersion == "fake@1")
        #expect(writer.requests.first?.moment.place == nil)
    }

    @Test("the lore's credit names Claude, the Wikipedia revision and the datasets")
    func loreCredit() {
        let lore = PackLore(
            text: "Where water runs, the dark sentinel waits.", tagline: "Keeper of the low perch.",
            sources: ["avonet", "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245", "birdbase"]
        )
        #expect(LoreText.credit(lore) == "Written by Claude (Anthropic) from this bird's fact sheet and reviewed by hand. Its facts come from its English Wikipedia article (revision 1361402245) by Wikipedia contributors, AVONET and BIRDBASE. Lore text: CC BY-SA 4.0.")
    }
}
