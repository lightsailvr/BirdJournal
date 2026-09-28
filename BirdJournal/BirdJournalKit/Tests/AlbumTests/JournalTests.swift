import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #28: the journal groups sightings by day, lists the distinct species, and searches by name.
@Suite("Journal")
struct JournalTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    static let english = Locale(identifier: "en_US")
    /// Sunday 2026-09-27 at 10:00 Los Angeles time.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))!

    /// Sightings in an in-memory album; the container lives as long as the holder, since a model outlives its
    /// context only as a trap.
    struct Album {
        let container: ModelContainer
        let sightings: [Sighting]
    }

    @MainActor
    private func album(_ entries: [(label: String, hoursAgo: Double)]) throws -> Album {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        var sightings: [Sighting] = []
        for entry in entries {
            let sighting = Sighting(speciesID: entry.label, confirmedAt: Self.now.addingTimeInterval(-entry.hoursAgo * 3_600), soundConfidence: 0.5, source: .phone)
            container.mainContext.insert(sighting)
            sightings.append(sighting)
        }
        try container.mainContext.save()
        return Album(container: container, sightings: sightings)
    }

    @Test("sightings group by day, newest day and newest sighting first")
    @MainActor
    func daysNewestFirst() throws {
        let album = try album([
            ("A_Old", 30 * 24), ("B_Yesterday", 20), ("C_Today early", 3), ("D_Today late", 1),
        ])

        let days = Journal.days(album.sightings.shuffled(), calendar: Self.calendar)

        #expect(days.map { $0.sightings.map(\.commonName) } == [["Today late", "Today early"], ["Yesterday"], ["Old"]])
        #expect(days.map(\.start) == days.map { Self.calendar.startOfDay(for: $0.sightings[0].confirmedAt) })
    }

    @Test("day headings read Today with the date, Yesterday, the weekday within a week, else the date")
    func dayTitles() {
        func title(daysAgo: Int) -> String {
            let day = Self.calendar.date(byAdding: .day, value: -daysAgo, to: Self.now)!
            return Journal.title(for: day, now: Self.now, calendar: Self.calendar, locale: Self.english)
        }
        #expect(title(daysAgo: 0) == "Today, September 27")
        #expect(title(daysAgo: 1) == "Yesterday")
        #expect(title(daysAgo: 2) == "Friday, September 25")
        #expect(title(daysAgo: 6) == "Monday, September 21")
        #expect(title(daysAgo: 7) == "September 20")
        #expect(title(daysAgo: 400) == "August 23, 2025")
    }

    @Test("the species list has one row per species with its count and latest sighting, latest first")
    @MainActor
    func speciesEntries() throws {
        let album = try album([
            ("Sayornis nigricans_Black Phoebe", 50), ("Calypte anna_Anna's Hummingbird", 10), ("Sayornis nigricans_Black Phoebe", 2),
        ])
        let sightings = album.sightings

        let species = Journal.species(sightings)

        #expect(species.map(\.commonName) == ["Black Phoebe", "Anna's Hummingbird"])
        #expect(species.map(\.count) == [2, 1])
        #expect(species[0].latest.confirmedAt == sightings[2].confirmedAt)
        #expect(species[0].scientificName == "Sayornis nigricans")
        #expect(Journal.summary(sightingCount: 3, speciesCount: 2) == "2 species · 3 sightings")
        #expect(Journal.summary(sightingCount: 1, speciesCount: 1) == "1 species · 1 sighting")
    }

    @Test("search matches word starts of the common or scientific name, ignoring case and accents")
    func search() {
        #expect(Journal.matches(query: "", commonName: "Black Phoebe", scientificName: "Sayornis nigricans"))
        #expect(Journal.matches(query: "phoe", commonName: "Black Phoebe", scientificName: "Sayornis nigricans"))
        #expect(Journal.matches(query: "SAYO nig", commonName: "Black Phoebe", scientificName: "Sayornis nigricans"))
        #expect(Journal.matches(query: "anna's", commonName: "Anna's Hummingbird", scientificName: "Calypte anna"))
        #expect(Journal.matches(query: "Nunez", commonName: "Núñez's Bird", scientificName: "Avis nunezi"))
        #expect(!Journal.matches(query: "lack", commonName: "Black Phoebe", scientificName: "Sayornis nigricans"), "no match inside a word")
        #expect(!Journal.matches(query: "black finch", commonName: "Black Phoebe", scientificName: "Sayornis nigricans"), "every term must match")
    }
}
