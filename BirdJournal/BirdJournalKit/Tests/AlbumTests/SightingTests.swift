import Foundation
import SwiftData
import Testing
@testable import Album

@Suite("Sighting")
struct SightingTests {
    @Test("a saved sighting can be fetched back with its fields intact")
    @MainActor
    func saveAndFetch() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext

        let sighting = Sighting(
            speciesID: "Sayornis nigricans_Black Phoebe",
            confirmedAt: Date(timeIntervalSince1970: 1_800_000_000),
            location: Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12),
            soundConfidence: 0.91,
            source: .glasses
        )
        context.insert(sighting)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Sighting>())
        #expect(fetched.count == 1)
        let saved = try #require(fetched.first)
        #expect(saved.speciesID == "Sayornis nigricans_Black Phoebe")
        #expect(saved.location == Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12))
        #expect(saved.soundConfidence == 0.91)
        #expect(saved.source == .glasses)
        #expect(saved.frameImagePath == nil)
    }
}
