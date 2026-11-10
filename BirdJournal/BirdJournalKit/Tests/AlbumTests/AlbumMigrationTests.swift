import Foundation
import SwiftData
import Testing
@testable import Album

// Issue #28: the journal adds a note to every sighting. An album written by the first schema, versioned or not, opens
// under the current one with every sighting, frame path and place intact and no note. Issue #51: schema 3 makes every
// sighting a card, so each one gets its own stable identifier and the method Heard, and keeps its note and frame.
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
            shipped.mainContext.insert(AlbumSchemaV1.Sighting(speciesID: "Turdus migratorius_American Robin", confirmedAt: .now, soundConfidence: 0.7, frameImagePath: "robin.jpg", source: .glasses))
            shipped.mainContext.insert(AlbumSchemaV1.Sighting(speciesID: "Turdus migratorius_American Robin", confirmedAt: .now.addingTimeInterval(-60), soundConfidence: 0.6, source: .phone))
            try shipped.mainContext.save()
        }

        let current = try AlbumSchema.makeContainer(at: url)
        let sightings = try current.mainContext.fetch(Sighting.newestFirst())
        #expect(sightings.map(\.commonName) == ["American Robin", "American Robin"])
        #expect(sightings.map(\.note) == [nil, nil])
        #expect(sightings.map(\.frameImagePath) == ["robin.jpg", nil])
        #expect(sightings.map(\.method) == [.heard, .heard])
        #expect(Set(sightings.map(\.identifier)).count == 2, "each its own identifier")
    }

    @Test("a store written by schema 2 opens under schema 3: every sighting gets its own identifier and Heard, and keeps its note, frame and place")
    @MainActor
    func schema2ToCards() throws {
        let url = try Self.storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let place = Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12)

        do {
            let v2 = try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV2.self), configurations: [ModelConfiguration(url: url)])
            let context = v2.mainContext
            context.insert(AlbumSchemaV2.Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), location: place, soundConfidence: 0.91, frameImagePath: "frame.jpg", source: .glasses, note: "Tail dipping over the pond."))
            context.insert(AlbumSchemaV2.Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_800_000_100), soundConfidence: 0.6, source: .phone))
            context.insert(AlbumSchemaV2.Sighting(speciesID: "Calypte anna_Anna's Hummingbird", confirmedAt: Date(timeIntervalSince1970: 1_800_000_200), soundConfidence: 0.7, source: .phone))
            try context.save()
        }

        let identifiers: [UUID]
        do {
            let v3 = try AlbumSchema.makeContainer(at: url)
            let sightings = try v3.mainContext.fetch(Sighting.newestFirst())
            #expect(sightings.map(\.commonName) == ["Anna's Hummingbird", "Black Phoebe", "Black Phoebe"])
            identifiers = sightings.map(\.identifier)
            #expect(Set(identifiers).count == 3, "every sighting has an identifier of its own")
            #expect(sightings.map(\.method) == [.heard, .heard, .heard])
            #expect(sightings.allSatisfy { $0.rarity == nil && $0.caption == nil && $0.art == CardArt() && $0.attachedPhotoPaths.isEmpty })
            let phoebe = try #require(sightings.last)
            #expect(phoebe.note == "Tail dipping over the pond.")
            #expect(phoebe.frameImagePath == "frame.jpg")
            #expect(phoebe.location == place)
            #expect(phoebe.source == .glasses)
            #expect(phoebe.soundConfidence == 0.91)

            phoebe.method = .seen
            try v3.mainContext.save()
        }

        let reopened = try AlbumSchema.makeContainer(at: url)
        let sightings = try reopened.mainContext.fetch(Sighting.newestFirst())
        #expect(sightings.map(\.identifier) == identifiers, "identifiers are assigned once and kept")
        #expect(sightings.map(\.method) == [.heard, .heard, .seen])
    }

    @Test("a store written by schema 1 opens under the current schema through every stage, with identifiers, Heard and its frame")
    @MainActor
    func schema1ToCards() throws {
        let url = try Self.storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let v1 = try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV1.self), configurations: [ModelConfiguration(url: url)])
            v1.mainContext.insert(AlbumSchemaV1.Sighting(speciesID: "Turdus migratorius_American Robin", confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), soundConfidence: 0.7, frameImagePath: "robin.jpg", source: .glasses))
            v1.mainContext.insert(AlbumSchemaV1.Sighting(speciesID: "Turdus migratorius_American Robin", confirmedAt: Date(timeIntervalSince1970: 1_800_000_060), soundConfidence: 0.8, source: .glasses))
            try v1.mainContext.save()
        }

        let current = try AlbumSchema.makeContainer(at: url)
        let sightings = try current.mainContext.fetch(Sighting.newestFirst())
        #expect(sightings.count == 2)
        #expect(Set(sightings.map(\.identifier)).count == 2)
        #expect(sightings.map(\.method) == [.heard, .heard])
        #expect(sightings.map(\.frameImagePath) == [nil, "robin.jpg"])
        #expect(sightings.map(\.note) == [nil, nil])
        #expect(sightings.map(\.namedByBirder) == [false, false])
    }

    // Issue #186: schema 4 marks a sighting the birder named. The shipped album is schema 3.

    @Test("a store written by schema 3 (the shipped album) opens under schema 4 with every sighting as it was and none named by the birder; one named afterwards stays named")
    @MainActor
    func schema3ToNamedSightings() throws {
        let url = try Self.storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let place = Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12)
        let phoebeID = UUID()

        do {
            let v3 = try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV3.self), configurations: [ModelConfiguration(url: url)])
            let phoebe = AlbumSchemaV3.Sighting(identifier: phoebeID, speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: Date(timeIntervalSince1970: 1_800_000_000), location: place, soundConfidence: 0.91, frameImagePath: "frame.jpg", source: .glasses, note: "Tail dipping over the pond.", method: .seen)
            phoebe.rarity = RaritySnapshot(occurrence: 0.42, label: .uncommon, calibrationVersion: 1, week: 41)
            phoebe.caption = CardCaption(text: "A phoebe kept the pond.", generatorVersion: "fm-1")
            phoebe.attachedPhotoPaths = ["mine.heic"]
            v3.mainContext.insert(phoebe)
            v3.mainContext.insert(AlbumSchemaV3.Sighting(speciesID: "Calypte anna_Anna's Hummingbird", confirmedAt: Date(timeIntervalSince1970: 1_800_000_200), soundConfidence: 0.7, source: .phone))
            try v3.mainContext.save()
        }

        do {
            let v4 = try AlbumSchema.makeContainer(at: url)
            let sightings = try v4.mainContext.fetch(Sighting.newestFirst())
            #expect(sightings.map(\.commonName) == ["Anna's Hummingbird", "Black Phoebe"])
            #expect(sightings.map(\.namedByBirder) == [false, false], "BirdNET heard every sighting the shipped album holds")
            let phoebe = try #require(sightings.last)
            #expect(phoebe.identifier == phoebeID, "identifiers are kept")
            #expect(phoebe.method == .seen)
            #expect(phoebe.note == "Tail dipping over the pond.")
            #expect(phoebe.frameImagePath == "frame.jpg")
            #expect(phoebe.location == place)
            #expect(phoebe.source == .glasses)
            #expect(phoebe.soundConfidence == 0.91)
            #expect(phoebe.rarity == RaritySnapshot(occurrence: 0.42, label: .uncommon, calibrationVersion: 1, week: 41))
            #expect(phoebe.caption?.text == "A phoebe kept the pond.")
            #expect(phoebe.attachedPhotoPaths == ["mine.heic"])

            let named = Sighting(speciesID: "Selasphorus sasin_Allen's Hummingbird", confirmedAt: Date(timeIntervalSince1970: 1_800_000_300), soundConfidence: 0, source: .phone, method: .seen, namedByBirder: true)
            named.attachedPhotoPaths = ["feeder.jpg"]
            v4.mainContext.insert(named)
            try v4.mainContext.save()
        }

        // One container per file at a time: the store is opened again after the first has gone.
        let reopened = try AlbumSchema.makeContainer(at: url)
        let sightings = try reopened.mainContext.fetch(Sighting.newestFirst())
        #expect(sightings.map(\.namedByBirder) == [true, false, false])
        #expect(sightings.first?.attachedPhotoPaths == ["feeder.jpg"])
        #expect(sightings.first?.method == .seen)
    }

    @Test("a store written by an unversioned schema of the shipped shape opens under schema 4 the same way")
    @MainActor
    func unversionedSchema3Migrates() throws {
        let url = try Self.storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let identifier = UUID()

        do {
            let shipped = try ModelContainer(for: Schema([AlbumSchemaV3.Sighting.self]), configurations: [ModelConfiguration(url: url)])
            let robin = AlbumSchemaV3.Sighting(identifier: identifier, speciesID: "Turdus migratorius_American Robin", confirmedAt: .now, soundConfidence: 0.7, frameImagePath: "robin.jpg", source: .glasses)
            robin.attachedPhotoPaths = ["robin-mine.jpg"]
            shipped.mainContext.insert(robin)
            try shipped.mainContext.save()
        }

        let current = try AlbumSchema.makeContainer(at: url)
        let robin = try #require(try current.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(robin.identifier == identifier)
        #expect(robin.frameImagePath == "robin.jpg")
        #expect(robin.attachedPhotoPaths == ["robin-mine.jpg"])
        #expect(robin.method == .heard)
        #expect(!robin.namedByBirder)
    }

    @Test("the card fields round-trip: rarity, caption, art and attached photos")
    @MainActor
    func cardFieldsRoundTrip() throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let sighting = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now, soundConfidence: 0.8, source: .glasses)
        let job = UUID()
        sighting.method = .seen
        sighting.rarity = RaritySnapshot(occurrence: 0.42, label: .uncommon, calibrationVersion: 1, week: 41)
        sighting.caption = CardCaption(text: "A finch sang the morning in.", generatorVersion: "fm-1")
        sighting.art = CardArt(prefersPackArt: true, scene: ArtImage(path: "scene.jpg", state: .ready), job: ArtJob(id: job, kind: .scene, state: .ready, attempts: 2))
        sighting.attachedPhotoPaths = ["mine.jpg"]
        album.mainContext.insert(sighting)
        try album.mainContext.save()

        let fetched = try #require(try album.mainContext.fetch(Sighting.newestFirst()).first)
        #expect(fetched.method == .seen)
        #expect(fetched.rarity == RaritySnapshot(occurrence: 0.42, label: .uncommon, calibrationVersion: 1, week: 41))
        #expect(fetched.caption?.text == "A finch sang the morning in.")
        #expect(fetched.art.scene == ArtImage(path: "scene.jpg", state: .ready))
        #expect(fetched.art.job?.id == job)
        #expect(fetched.art.prefersPackArt)
        #expect(fetched.attachedPhotoPaths == ["mine.jpg"])
    }

    private static func storeURL() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "album-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "album.store")
    }
}

