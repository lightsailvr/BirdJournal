import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #11: the album lists sightings newest first, and names them from the BirdNET label when the pack has no
// entry (spec user story 40: every species stays identifiable by name).
@Suite("Album order and names")
struct AlbumOrderTests {
    @Test("the album descriptor fetches sightings in reverse chronological order")
    @MainActor
    func newestFirst() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        for (label, seconds) in [("B_Second", 200.0), ("A_First", 100.0), ("C_Third", 300.0)] {
            context.insert(Sighting(speciesID: label, confirmedAt: Date(timeIntervalSince1970: seconds), soundConfidence: 0.5, source: .phone))
        }
        try context.save()

        let fetched = try context.fetch(Sighting.newestFirst())

        #expect(fetched.map(\.speciesID) == ["C_Third", "B_Second", "A_First"])
    }

    @Test("a BirdNET label splits into scientific and common names")
    func labelNames() {
        let sighting = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.9, source: .glasses)
        #expect(sighting.scientificName == "Sayornis nigricans")
        #expect(sighting.commonName == "Black Phoebe")
    }

    @Test("a label without an underscore is its own common name")
    func bareLabel() {
        let sighting = Sighting(speciesID: "Unknown bird", confirmedAt: .now, soundConfidence: 0.9, source: .glasses)
        #expect(sighting.scientificName == "Unknown bird")
        #expect(sighting.commonName == "Unknown bird")
    }

    @Test("a coordinate reads as degrees with hemispheres")
    func coordinateText() {
        let english = Locale(identifier: "en_US")
        #expect(Coordinate(latitude: 34.0522, longitude: -118.2437, accuracy: 10).formatted(locale: english) == "34.05° N, 118.24° W")
        #expect(Coordinate(latitude: -33.8688, longitude: 151.2093, accuracy: 10).formatted(locale: english) == "33.87° S, 151.21° E")
        #expect(Coordinate(latitude: 34.0522, longitude: -118.2437, accuracy: 10).formatted(locale: Locale(identifier: "de_DE")) == "34,05° N, 118,24° W")
    }
}
