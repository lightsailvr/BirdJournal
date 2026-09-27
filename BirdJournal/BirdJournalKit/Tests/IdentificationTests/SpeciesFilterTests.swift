import Foundation
import Testing
@testable import Identification

@Suite("SpeciesFilter")
struct SpeciesFilterTests {
    private let finch = Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")
    private let jay = Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves")
    private let dog = Species(index: 2, scientificName: "Canis familiaris", commonName: "Domestic Dog", taxonomicClass: "Mammalia")
    private let unknown = Species(index: 3, scientificName: "Acanthis cabaret", commonName: "Lesser Redpoll", taxonomicClass: "Aves")

    @Test("species at or above the occurrence threshold pass, others and unknowns do not")
    func thresholdAndUnknown() {
        let allowed = SpeciesFilter.allowed(
            species: [finch, jay, dog, unknown],
            occurrence: ["Haemorhous mexicanus": 0.03, "Cyanocitta cristata": 0.029, "Canis familiaris": 0.9],
            threshold: 0.03,
            taxonomicClasses: nil
        )
        #expect(allowed == [true, false, true, false])
    }

    @Test("a class restriction drops species outside it even when the prior likes them")
    func classRestriction() {
        let allowed = SpeciesFilter.allowed(
            species: [finch, dog],
            occurrence: ["Haemorhous mexicanus": 0.9, "Canis familiaris": 0.9],
            threshold: 0.03,
            taxonomicClasses: [Species.birds]
        )
        #expect(allowed == [true, false])
    }

    @Test("with no prior (no location), every species in the allowed classes passes, unknowns included")
    func noPrior() {
        let allowed = SpeciesFilter.allowed(species: [finch, jay, dog, unknown], occurrence: nil, threshold: 0.03, taxonomicClasses: [Species.birds])
        #expect(allowed == [true, true, false, true])
    }
}

@Suite("GeoContext")
struct GeoContextTests {
    @Test("dates map onto BirdNET's 48-week year", arguments: [
        ("2026-01-01", 1), ("2026-01-07", 1), ("2026-01-08", 2), ("2026-01-22", 4), ("2026-01-31", 4),
        ("2026-09-26", 36), ("2026-12-31", 48),
    ])
    func week(iso: String, expected: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let date = try #require(formatter.date(from: iso))
        #expect(GeoContext.week(of: date, calendar: calendar) == expected)
    }
}
