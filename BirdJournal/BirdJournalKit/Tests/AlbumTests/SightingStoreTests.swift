import Foundation
import SwiftData
import Testing
@testable import Album

@Suite("Sighting store")
struct SightingStoreTests {
    @Test("a saved sighting can be fetched back")
    @MainActor
    func saveAndFetch() throws {
        let container = try AlbumSchema.makeContainer(inMemory: true)
        let context = container.mainContext

        let sighting = Sighting(
            speciesLabel: "Sayornis nigricans_Black Phoebe",
            commonName: "Black Phoebe",
            confidence: 0.91,
            heardAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        context.insert(sighting)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Sighting>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.commonName == "Black Phoebe")
        #expect(fetched.first?.confidence == 0.91)
    }
}
