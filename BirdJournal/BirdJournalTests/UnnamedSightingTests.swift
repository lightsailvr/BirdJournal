import Album
import Foundation
import Identification
import Pack
import SwiftData
import Testing
import UIKit
@testable import BirdJournal

// Issue #188 (of #185): photo first, name second. The photo is written the moment it is taken, as a capture (in copy, an
// unnamed sighting), and waits for its name for as long as it takes. Until it has one it is no sighting: it sews no patch,
// moves no set and publishes no find. Naming it writes the sighting with the capture's own time and place.
@Suite("Unnamed sightings")
@MainActor
struct UnnamedSightingTests {
    static let allens = SeenSightingTests.allens
    static let finch = SeenSightingTests.finch
    static let losFeliz = SeenSightingTests.losFeliz
    static let taken = SeenSightingTests.taken

    struct Fixture {
        let album: ModelContainer
        let frames: FrameStore
        let ledger: RunSightings
        let prior: ScriptedOccurrence

        var sightings: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
        var captures: [Capture] { (try? album.mainContext.fetch(Capture.newestFirst())) ?? [] }
        var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: frames.directory.path(percentEncoded: false))) ?? [] }
        var collection: CardCollection { CardCollection(sightings: sightings, sets: [SeenSightingTests.losAngeles]) }
    }

    static func makeFixture(album: ModelContainer? = nil, frames: FrameStore? = nil) throws -> Fixture {
        let album = try album ?? AlbumSchema.makeContainer(inMemory: true)
        let frames = frames ?? FrameStore(directory: URL.temporaryDirectory.appending(path: "unnamed-\(UUID().uuidString)", directoryHint: .isDirectory))
        let prior = ScriptedOccurrence(["Selasphorus sasin": 0.75, "Haemorhous mexicanus": 0.25])
        let recorder = SightingRecorder(container: album, frames: frames, rarity: RarityReader(occurrenceModel: prior, calibration: .forTests))
        recorder.sets = { [SeenSightingTests.losAngeles] }
        return Fixture(album: album, frames: frames, ledger: RunSightings(recorder: recorder), prior: prior)
    }

    // MARK: - At the shutter

    @Test("a capture is written at the shutter with its photo, time, place and source; it is no sighting, sews no patch, moves no set and publishes no find")
    func writtenAtTheShutter() async throws {
        let fixture = try Self.makeFixture()
        let client = FindRecorder()
        let outbox = FindOutbox(account: FakeAccount.session(signedIn: true), client: client, fileURL: nil, sharing: { .automatic }, payload: { _, _ in nil })
        fixture.ledger.findOutbox = outbox
        let photo = DebugSeeds.frameJPEG()

        let unnamed = try fixture.ledger.capture(photo: photo, takenAt: Self.taken, location: Self.losFeliz, source: .phone)

        let capture = try #require(fixture.captures.first)
        #expect(fixture.captures.count == 1)
        #expect(capture.identifier == unnamed.id)
        #expect(capture.takenAt == Self.taken)
        #expect(capture.location == Self.losFeliz)
        #expect(capture.source == .phone)
        #expect(capture.photoPath.hasSuffix(".jpeg"), "what the picture is: \(capture.photoPath)")
        #expect(try Data(contentsOf: fixture.frames.url(for: capture.photoPath)) == photo, "kept as it came")
        #expect(unnamed == UnnamedSighting(id: capture.identifier, takenAt: Self.taken, location: Self.losFeliz, photoPath: capture.photoPath, source: .phone))
        #expect(fixture.ledger.unnamed == [unnamed], "the run lists it")

        #expect(fixture.sightings.isEmpty, "not a sighting")
        #expect(fixture.ledger.seen.isEmpty && fixture.ledger.entries.isEmpty && fixture.ledger.identifiers.isEmpty)
        #expect(fixture.collection.patchCount == 0, "no patch")
        #expect(fixture.collection.progress(of: "us-ca-la").collected == 0, "no set's progress")
        #expect(fixture.prior.asked.isEmpty, "no rarity is read for a bird with no name")
        await outbox.flush()
        #expect(client.calls.isEmpty, "no find")

        let fromGlasses = try fixture.ledger.capture(photo: Data([7]), takenAt: Self.taken.addingTimeInterval(60), location: nil, source: .glasses)
        #expect(fromGlasses.source == .glasses && fromGlasses.location == nil)
        #expect(fixture.ledger.unnamed == [unnamed, fromGlasses], "in the order taken")
    }

    @Test("a capture survives the app being killed before it is named: the album on disk has it at the next launch, with its photo")
    func survivesTheAppBeingKilled() throws {
        let folder = URL.temporaryDirectory.appending(path: "unnamed-album-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = FrameStore(directory: folder.appending(path: "Frames", directoryHint: .isDirectory))
        let url = folder.appending(path: "album.store")
        let photo = DebugSeeds.frameJPEG()

        let identifier: UUID
        do {
            // The shutter, and nothing after it: no name, no close, no save but the one the shutter made.
            let fixture = try Self.makeFixture(album: AlbumSchema.makeContainer(at: url), frames: frames)
            identifier = try fixture.ledger.capture(photo: photo, takenAt: Self.taken, location: Self.losFeliz, source: .phone).id
        }

        // One container per file at a time: the next launch opens the store after the first has gone.
        let relaunched = try Self.makeFixture(album: AlbumSchema.makeContainer(at: url), frames: frames)
        let capture = try #require(relaunched.captures.first)
        #expect(capture.identifier == identifier)
        #expect(capture.takenAt == Self.taken)
        #expect(capture.location == Self.losFeliz)
        #expect(capture.source == .phone)
        #expect(try Data(contentsOf: frames.url(for: capture.photoPath)) == photo)
        #expect(relaunched.sightings.isEmpty)
        #expect(relaunched.ledger.unnamed.isEmpty, "a new launch's run starts with none of its own; the album has it")
    }

    // MARK: - Naming

    @Test("naming a capture writes the sighting with the capture's time, place, source and photo, not the time of naming, reads the rarity for that place and week, and the capture is gone")
    func namingWritesTheSighting() throws {
        let fixture = try Self.makeFixture()
        let photo = DebugSeeds.frameJPEG()
        // Taken in 2027 by this test's clock, and named now.
        let unnamed = try fixture.ledger.capture(photo: photo, takenAt: Self.taken, location: Self.losFeliz, source: .phone)

        let addition = try fixture.ledger.name(unnamed, as: Self.allens)

        #expect(fixture.captures.isEmpty, "it is a sighting now")
        #expect(fixture.ledger.unnamed.isEmpty)
        let sighting = try #require(fixture.sightings.first)
        #expect(fixture.sightings.count == 1)
        #expect(sighting.identifier == addition.identifier)
        #expect(sighting.speciesID == "Selasphorus sasin_Allen's Hummingbird")
        #expect(sighting.method == .seen && sighting.namedByBirder)
        #expect(sighting.confirmedAt == Self.taken, "the capture's time, not the time it was named")
        #expect(sighting.location == Self.losFeliz, "the capture's place")
        #expect(sighting.source == .phone)
        let week = GeoContext.week(of: Self.taken)
        #expect(sighting.rarity == RaritySnapshot(occurrence: 0.75, label: .common, calibrationVersion: 7, week: week))
        #expect(fixture.prior.asked == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)], "read for the capture's place and week")
        #expect(sighting.attachedPhotoPaths == [unnamed.photoPath], "the same file, now the sighting's original photo")
        #expect(fixture.files == [unnamed.photoPath])
        #expect(try Data(contentsOf: fixture.frames.url(for: unnamed.photoPath)) == photo)

        #expect(addition.sewsPatch && addition.patchCount == 1, "it sews its patch, as any add")
        #expect(addition.placement.setName == "Los Angeles")
        #expect(addition.species.commonName == "Allen's Hummingbird")
        #expect(fixture.ledger.seen.map(\.identifier) == [addition.identifier])
        #expect(fixture.ledger.seen.first?.seenAt == Self.taken)
        #expect(fixture.ledger.identifiers == [addition.identifier])
        #expect(fixture.collection.progress(of: "us-ca-la").collected == 1)
    }

    @Test("a capture the glasses took is a sighting from the glasses once named; one with no place is named with none, in Uncharted and without rarity")
    func namingKeepsTheSourceAndThePlace() throws {
        let fixture = try Self.makeFixture()
        let fromGlasses = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .glasses)
        let nowhere = try fixture.ledger.capture(photo: Data([2]), takenAt: Self.taken.addingTimeInterval(60), location: nil, source: .phone)

        try fixture.ledger.name(fromGlasses, as: Self.allens)
        let placeless = try fixture.ledger.name(nowhere, as: Self.finch)

        let sightings = fixture.sightings
        #expect(sightings.map(\.source) == [.phone, .glasses])
        #expect(sightings.last.map(CardText.how) == "Seen, photographed with Ray-Ban Display")
        #expect(sightings.first?.location == nil)
        #expect(sightings.first?.rarity == nil)
        #expect(placeless.placement == .uncharted)
    }

    @Test("naming publishes the find, which says saw and when the photo was taken; until then nothing was published, and Undo takes it back")
    func namingPublishesTheFind() async throws {
        let fixture = try Self.makeFixture()
        let client = FindRecorder()
        let library = PackLibrary(bundled: nil, storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "unnamed-packs-\(UUID().uuidString)")), bundledCovers: .none)
        let places = PlaceNames()
        let outbox = FindOutbox(
            account: FakeAccount.session(signedIn: true), client: client, fileURL: nil, sharing: { .automatic },
            payload: { [album = fixture.album] identifier, isNewPatch in
                await FindOutbox.find(of: identifier, isNewPatch: isNewPatch, album: album, packs: library, places: places)
            }
        )
        fixture.ledger.findOutbox = outbox
        // No place, so nothing asks the network for a city.
        let unnamed = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: nil, source: .phone)
        await outbox.flush()
        #expect(client.calls.isEmpty)

        let addition = try fixture.ledger.name(unnamed, as: Self.allens)
        await outbox.flush()

        let find = try #require(client.puts[addition.identifier])
        #expect(find.method == .seen)
        #expect(find.commonName == "Allen's Hummingbird")
        #expect(find.newPatch)
        #expect(find.foundAt == FindPolicy.minute(Self.taken), "when the photo was taken")
        #expect(client.calls == ["put \(addition.identifier)"])

        // Undo takes the find back with the name.
        try fixture.ledger.undo(addition)
        await outbox.flush()
        #expect(client.puts.isEmpty)
        #expect(client.calls == ["put \(addition.identifier)", "delete \(addition.identifier)"])
    }

    @Test("a capture from an earlier run is named all the same, with its own time and place, and is not listed as seen on this run")
    func namingACaptureOfAnEarlierRun() throws {
        let fixture = try Self.makeFixture()
        let earlier = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .phone)
        fixture.ledger.reset()
        #expect(fixture.ledger.unnamed.isEmpty, "a new run starts with none of its own")
        #expect(fixture.captures.count == 1, "the album keeps it")

        let addition = try fixture.ledger.name(earlier, as: Self.allens)

        #expect(fixture.sightings.map(\.confirmedAt) == [Self.taken])
        #expect(fixture.sightings.first?.location == Self.losFeliz)
        #expect(addition.sewsPatch)
        #expect(fixture.ledger.seen.isEmpty && fixture.ledger.identifiers.isEmpty, "it wasn't seen on this run")
        #expect(fixture.ledger.canUndo(addition), "the add can still be taken back")
        #expect(fixture.captures.isEmpty)
    }

    @Test("a capture that has gone, named or deleted meanwhile, can't be named again")
    func namingWhatHasGone() throws {
        let fixture = try Self.makeFixture()
        let unnamed = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: nil, source: .phone)
        try fixture.ledger.name(unnamed, as: Self.allens)

        #expect(throws: UnnamedSightingFailure.gone) { try fixture.ledger.name(unnamed, as: Self.finch) }
        #expect(fixture.sightings.count == 1)
    }

    @Test("a photo taken and named in one step goes the same way: the sighting holds the photo, and no capture is left")
    func takenAndNamedAtOnce() throws {
        let fixture = try Self.makeFixture()
        let addition = try fixture.ledger.addSeen(Self.allens, photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .phone)
        #expect(fixture.captures.isEmpty && fixture.ledger.unnamed.isEmpty)
        #expect(fixture.sightings.map(\.identifier) == [addition.identifier])
        #expect(fixture.files.count == 1)
    }

    // MARK: - Undo and delete

    @Test("Undo of a naming takes the name back and keeps the photo: the sighting and its patch go, and the unnamed sighting waits again with its time, place and source")
    func undoTakesTheNameBack() throws {
        let fixture = try Self.makeFixture()
        let first = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .glasses)
        let second = try fixture.ledger.capture(photo: Data([2]), takenAt: Self.taken.addingTimeInterval(60), location: nil, source: .phone)
        let addition = try fixture.ledger.name(first, as: Self.allens)
        #expect(fixture.ledger.unnamed == [second])

        try fixture.ledger.undo(addition)

        #expect(fixture.sightings.isEmpty, "the sighting is gone")
        #expect(fixture.collection.patchCount == 0, "and its patch with it")
        #expect(fixture.ledger.seen.isEmpty && fixture.ledger.identifiers.isEmpty)
        #expect(!fixture.ledger.canUndo(addition))
        let waiting = try #require(fixture.ledger.unnamed.first)
        #expect(fixture.ledger.unnamed.count == 2 && fixture.ledger.unnamed.last == second, "back where it was, in the order taken")
        #expect(waiting.takenAt == Self.taken && waiting.location == Self.losFeliz && waiting.source == .glasses)
        #expect(waiting.photoPath == first.photoPath, "the same photo")
        #expect(Set(fixture.captures.map(\.identifier)) == [waiting.id, second.id], "in the album again")
        #expect(fixture.files.count == 2, "no photo was lost: \(fixture.files)")

        // It can be named again, as another bird.
        let again = try fixture.ledger.name(waiting, as: Self.finch)
        #expect(fixture.sightings.map(\.commonName) == ["House Finch"])
        #expect(fixture.sightings.first?.confirmedAt == Self.taken)
        #expect(again.sewsPatch)
        try fixture.ledger.undo(again)
        try fixture.ledger.undo(again)
        #expect(fixture.captures.count == 2 && fixture.sightings.isEmpty)
    }

    @Test("deleting an unnamed sighting removes it and its photo, and only that one")
    func deleteRemovesItAndItsPhoto() throws {
        let fixture = try Self.makeFixture()
        let first = try fixture.ledger.capture(photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .phone)
        let second = try fixture.ledger.capture(photo: Data([2]), takenAt: Self.taken.addingTimeInterval(60), location: nil, source: .phone)

        try fixture.ledger.delete(first)

        #expect(fixture.captures.map(\.identifier) == [second.id])
        #expect(fixture.ledger.unnamed == [second])
        #expect(fixture.files == [second.photoPath], "its photo went with it, and only its photo")
        #expect(fixture.sightings.isEmpty)

        // Gone already: nothing more happens.
        try fixture.ledger.delete(first)
        #expect(fixture.captures.count == 1)

        // One of an earlier run is deleted from the album all the same.
        fixture.ledger.reset()
        try fixture.ledger.delete(second)
        #expect(fixture.captures.isEmpty && fixture.files.isEmpty)
    }
}
