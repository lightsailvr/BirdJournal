import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #28: the journal adds a note to every sighting. An album written by the first schema, versioned or not, opens
// under the current one with every sighting, frame path and place intact and no note.
@Suite("Album migration")
struct AlbumMigrationTests {
    @Test("a store written by schema 1 opens under schema 2 with its sightings intact and empty notes")
    @MainActor
    func lightweightMigration() throws {
        let folder = URL.temporaryDirectory.appending(path: "album-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "album.store")

        do {
            let v1 = try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV1.self), configurations: [ModelConfiguration(url: url)])
            let context = v1.mainContext
            context.insert(AlbumSchemaV1.Sighting(
                speciesID: "Sayornis nigricans_Black Phoebe",
                confirmedAt: Date(timeIntervalSince1970: 1_800_000_000),
                location: Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12),
                soundConfidence: 0.91,
                frameImagePath: "frame.jpg",
                source: .glasses
            ))
            context.insert(AlbumSchemaV1.Sighting(speciesID: "Calypte anna_Anna's Hummingbird", confirmedAt: Date(timeIntervalSince1970: 1_800_000_100), soundConfidence: 0.6, source: .phone))
            try context.save()
        }

        do {
            let v2 = try AlbumSchema.makeContainer(at: url)
            let sightings = try v2.mainContext.fetch(Sighting.newestFirst())

            #expect(sightings.map(\.speciesID) == ["Calypte anna_Anna's Hummingbird", "Sayornis nigricans_Black Phoebe"])
            let phoebe = try #require(sightings.last)
            #expect(phoebe.location == Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12))
            #expect(phoebe.soundConfidence == 0.91)
            #expect(phoebe.frameImagePath == "frame.jpg")
            #expect(phoebe.source == .glasses)
            #expect(phoebe.note == nil)

            phoebe.note = "Tail dipping over the pond."
            try v2.mainContext.save()
        }

        // One container per file at a time: the store is opened again after the first has gone.
        let reopened = try AlbumSchema.makeContainer(at: url)
        let notes = try reopened.mainContext.fetch(Sighting.newestFirst()).map(\.note)
        #expect(notes == [nil, "Tail dipping over the pond."])
    }

    @Test("a store written by an unversioned schema of the first shape (the album as shipped) opens the same way")
    @MainActor
    func unversionedStoreMigrates() throws {
        let folder = URL.temporaryDirectory.appending(path: "album-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "album.store")

        do {
            let shipped = try ModelContainer(for: Schema([AlbumSchemaV1.Sighting.self]), configurations: [ModelConfiguration(url: url)])
            shipped.mainContext.insert(AlbumSchemaV1.Sighting(speciesID: "Turdus migratorius_American Robin", confirmedAt: .now, soundConfidence: 0.7, source: .glasses))
            try shipped.mainContext.save()
        }

        let current = try AlbumSchema.makeContainer(at: url)
        let sightings = try current.mainContext.fetch(Sighting.newestFirst())
        #expect(sightings.map(\.commonName) == ["American Robin"])
        #expect(sightings.first?.note == nil)
    }
}
