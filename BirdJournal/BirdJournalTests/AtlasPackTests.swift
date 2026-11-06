import Album
import Foundation
import Pack
import SwiftData
import Testing
@testable import BirdJournal

/// Issue #118 (design guide page 14): a download adds reference material, never birds, and removing a pack never
/// touches a sighting, note or original photo. The album and the photos live apart from the packs, so a pack coming
/// and going leaves them as they were.
@Suite("The Atlas's packs and the collection", .serialized)
@MainActor
struct AtlasPackCollectionTests {
    @Test("downloading a pack adds no birds, and removing it keeps every sighting, note and original photo")
    func packsLeaveTheCollectionAlone() throws {
        let root = URL.temporaryDirectory.appending(path: "AtlasPackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs", directoryHint: .isDirectory))
        let frames = root.appending(path: "Frames", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // Two sightings, one with a note, a glasses photo and an attached original photo.
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let photo = frames.appending(path: "phoebe.jpg")
        let original = frames.appending(path: "phoebe-original.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: photo)
        try Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9]).write(to: original)
        let phoebe = Sighting(speciesID: "Sayornis nigricans_Black Phoebe", confirmedAt: .now, soundConfidence: 0.8, frameImagePath: "phoebe.jpg", source: .glasses)
        phoebe.note = "Tail dipping over the pond"
        phoebe.attachedPhotoPaths = ["phoebe-original.jpg"]
        let finch = Sighting(speciesID: "Haemorhous mexicanus_House Finch", confirmedAt: .now.addingTimeInterval(-60), soundConfidence: 0.7, source: .phone)
        album.mainContext.insert(phoebe)
        album.mainContext.insert(finch)
        try album.mainContext.save()

        func sightings() throws -> [Sighting] { try album.mainContext.fetch(FetchDescriptor<Sighting>()) }
        let before = CardCollection(sightings: try sightings(), sets: PackLibrary(bundled: nil, storage: storage).cardSets)
        #expect(before.speciesCount == 2)

        // "Download" the Los Angeles pack: the installed copy, as `PackStorage.install` leaves it.
        let bundled = try SpeciesPack.bundled()
        let folder = storage.url(for: bundled.info.id)
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled.directory, to: folder)
        let descriptor = PackDescriptor(
            id: bundled.info.id, name: bundled.info.name, version: bundled.info.version, url: URL(string: "https://example.invalid/la.zip")!,
            sha256: "", byteCount: 1, speciesCount: bundled.species.count
        )
        try JSONEncoder().encode(descriptor).write(to: folder.appending(path: "installed.json"))
        let library = PackLibrary(bundled: nil, storage: storage)
        #expect(library.pack(id: bundled.info.id) != nil, "the download is ready offline")
        #expect(try sightings().count == 2, "a download adds no sightings")
        #expect(CardCollection(sightings: try sightings(), sets: library.cardSets).speciesCount == before.speciesCount, "a download adds no birds to the collection")

        // Remove it.
        try library.remove(id: bundled.info.id)
        #expect(library.pack(id: bundled.info.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        let after = try sightings()
        #expect(after.count == 2, "removing a pack keeps every sighting")
        let kept = try #require(after.first { $0.identifier == phoebe.identifier })
        #expect(kept.note == "Tail dipping over the pond", "and every note")
        #expect(kept.frameImagePath == "phoebe.jpg")
        #expect(kept.attachedPhotoPaths == ["phoebe-original.jpg"])
        #expect(FileManager.default.fileExists(atPath: photo.path(percentEncoded: false)), "and the glasses photo")
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)), "and the original photo")
        #expect(CardCollection(sightings: after, sets: library.cardSets).speciesCount == before.speciesCount, "and the collection")
    }
}

/// Each failed download gets its own recovery (design guide page 14), sorted from the words `PackLibrary` gives it.
@Suite("A failed pack download's recovery")
struct PackFailureTests {
    @Test("no connection, an interrupted transfer, a failed install and low storage each get their own title and action")
    func kinds() {
        let offline = PackFailure(message: "No internet connection. Connect to Wi‑Fi or cellular data and try again.")
        #expect(offline.kind == .offline)
        #expect(offline.action == "Try again")
        #expect(PackFailure(message: "The pack server could not be reached. Try again later.").kind == .offline)

        let dropped = PackFailure(message: "The connection dropped before the download finished. Try again.")
        #expect(dropped.kind == .interrupted)
        #expect(dropped.title == "The download was interrupted")
        #expect(PackFailure(message: "The download timed out. Try again.").kind == .interrupted)

        let space = PackFailure(message: "Not enough space on this iPhone: the download needs about 450 MB free and 212 MB is available. Free some space and try again.")
        #expect(space.kind == .lowStorage)
        #expect(space.title == "Not enough space")
        #expect(space.action == "Check again")
        #expect(space.advice?.contains("Nothing in your collection is touched") == true)
        #expect(PackFailure(message: "This iPhone ran out of space during the download. Free some space and try again.").kind == .lowStorage)

        let checksum = PackFailure(message: "The download's checksum did not match the index, so it was not installed. Try again.")
        #expect(checksum.kind == .install)
        #expect(checksum.action == "Download again")
        #expect(PackFailure(message: "The download is not a readable pack (malformed).").kind == .install)
    }
}

/// The Atlas's designed fallback names its landscape from the edition, and a Guild's look comes from its ID alone.
@Suite("Set and Guild identity")
struct AtlasIdentityTests {
    @Test("an edition's name picks its landscape")
    func editions() {
        #expect(Landscape(edition: "Citrus edition") == .citrus)
        #expect(Landscape(edition: "Coastal edition") == .coastal)
        #expect(Landscape(edition: "Fog edition") == .fog)
        #expect(Landscape(edition: "Desert edition") == .desert)
        #expect(Landscape(edition: "Wetland edition") == .wetland)
        #expect(Landscape(edition: "Mountain edition") == .hills)
    }

    @Test("a Guild's emblem and cover are stable for its ID, and never gold")
    func guilds() {
        #expect(GuildIdentity(circleID: "c-1") == GuildIdentity(circleID: "c-1"))
        let looks = Set((0..<200).map { GuildIdentity(circleID: "circle-\($0)").tone.name })
        #expect(looks.count > 3, "Guilds don't all look alike")
        #expect(!GuildIdentity.tones.map(\.name).contains("gold"))
        #expect(GuildIdentity.habitats.allSatisfy { ![.citrus, .desert].contains($0) }, "the warm editions stay with their sets")
    }
}
