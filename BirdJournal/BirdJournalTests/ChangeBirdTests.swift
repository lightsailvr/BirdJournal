import Album
import Foundation
import Identification
import Pack
import SwiftData
import Testing
@testable import BirdJournal

// Issue #190 (of #185): a sighting the birder named can be given another bird. The sighting stays the same sighting, with
// its photo, time, place and note; what is derived from its bird follows: the old bird's patch loses it (and is unpicked
// if it was the last there), the new bird's patch gains it or is sewn, the rarity is read again for the new bird at the
// sighting's own place and week, the caption written for the old bird goes, and a published find is put again. No
// stitch-in plays: that ceremony belongs to the add. A heard sighting's bird can't be changed.
@Suite("Change a seen sighting's bird")
@MainActor
struct ChangeBirdTests {
    static let allens = SeenSightingTests.allens
    static let finch = SeenSightingTests.finch
    static let hermit = SeenSightingTests.hermit
    static let losFeliz = SeenSightingTests.losFeliz
    static let taken = SeenSightingTests.taken
    static let losAngeles = SeenSightingTests.losAngeles

    struct Fixture {
        let album: ModelContainer
        let frames: FrameStore
        let ledger: RunSightings
        let edits: JournalEdits
        let prior: ScriptedOccurrence

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
        var collection: CardCollection { CardCollection(sightings: stored, sets: [ChangeBirdTests.losAngeles]) }

        /// A photo named as `bird`, as the run writes it.
        @discardableResult
        func named(_ bird: NameableBird, at takenAt: Date = ChangeBirdTests.taken, location: Coordinate? = ChangeBirdTests.losFeliz) throws -> Sighting {
            let addition = try ledger.addSeen(bird, photo: DebugSeeds.frameJPEG(), takenAt: takenAt, location: location, source: .phone)
            return try #require(stored.first { $0.identifier == addition.identifier })
        }
    }

    static func makeFixture() throws -> Fixture {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "change-bird-\(UUID().uuidString)", directoryHint: .isDirectory))
        let prior = ScriptedOccurrence(["Selasphorus sasin": 0.75, "Haemorhous mexicanus": 0.25])
        let recorder = SightingRecorder(container: album, frames: frames, rarity: RarityReader(occurrenceModel: prior, calibration: .forTests))
        recorder.sets = { [losAngeles] }
        return Fixture(album: album, frames: frames, ledger: RunSightings(recorder: recorder), edits: JournalEdits(container: album, frames: frames, recorder: recorder), prior: prior)
    }

    @Test("after a change the sighting is the new bird's, with its own photo, time, place and note; its patch is the new bird's and the old bird's patch, which had no other sighting there, is unpicked")
    func theSightingBecomesTheNewBirds() throws {
        let fixture = try Self.makeFixture()
        let sighting = try fixture.named(Self.allens)
        let identifier = sighting.identifier
        let photo = sighting.attachedPhotoPaths
        fixture.edits.setNote("At the feeder, silent.", on: sighting)
        #expect(fixture.collection.patch(of: identifier)?.scientificName == "Selasphorus sasin")

        #expect(fixture.edits.changeBird(of: sighting, to: Self.finch))

        #expect(fixture.stored.count == 1, "the same sighting, not another")
        let changed = try #require(fixture.stored.first)
        #expect(changed.identifier == identifier)
        #expect(changed.speciesID == "Haemorhous mexicanus_House Finch")
        #expect(changed.method == .seen && changed.namedByBirder, "still a bird the birder saw and named")
        #expect(changed.confirmedAt == Self.taken)
        #expect(changed.location == Self.losFeliz)
        #expect(changed.attachedPhotoPaths == photo, "its photo stays its original photo")
        #expect(changed.note == "At the feeder, silent.", "the birder's own words stay")
        #expect(fixture.edits.errorMessage == nil)

        let collection = fixture.collection
        let patch = try #require(collection.patch(of: identifier))
        #expect(patch.scientificName == "Haemorhous mexicanus")
        #expect(patch.count == 1)
        #expect(patch.placement.collectorNumber == "001/002", "the new bird's place in the set")
        #expect(collection.patches(of: Self.allens.speciesID).isEmpty, "the old bird's patch is unpicked")
        #expect(collection.patchCount == 1)
        #expect(collection.collected(in: "us-ca-la") == ["Haemorhous mexicanus"], "the set's progress is the new bird's")
        #expect(collection.progress(of: "us-ca-la").collected == 1)
    }

    @Test("a patch with other sightings keeps them: the old bird's patch loses one, the new bird's gains one, and a bird outside every set lands in Uncharted")
    func patchesWithOtherSightings() throws {
        let fixture = try Self.makeFixture()
        try fixture.named(Self.allens, at: Self.taken.addingTimeInterval(-3600))
        try fixture.ledger.add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.taken.addingTimeInterval(-60), location: Self.losFeliz, frame: nil, source: .phone)
        let sighting = try fixture.named(Self.allens)
        #expect(fixture.collection.patch(of: sighting.identifier)?.count == 2)
        #expect(fixture.collection.progress(of: "us-ca-la").collected == 2)

        #expect(fixture.edits.changeBird(of: sighting, to: Self.finch))

        var collection = fixture.collection
        #expect(collection.patch(of: sighting.identifier)?.scientificName == "Haemorhous mexicanus")
        #expect(collection.patch(of: sighting.identifier)?.count == 2, "with the one heard")
        #expect(collection.patches(of: Self.allens.speciesID).map(\.count) == [1], "the old bird keeps its patch and its other sighting")
        #expect(collection.progress(of: "us-ca-la").collected == 2)

        #expect(fixture.edits.changeBird(of: sighting, to: Self.hermit))

        collection = fixture.collection
        #expect(collection.patch(of: sighting.identifier)?.placement == .uncharted, "no set lists it")
        #expect(collection.unchartedSpeciesCount == 1)
        #expect(collection.patches(of: Self.finch.speciesID).map(\.count) == [1])
        #expect(collection.progress(of: "us-ca-la").collected == 2, "both set birds still have a sighting there")
    }

    @Test("the rarity is read again for the new bird, at the sighting's own place and in the week it was taken")
    func rarityIsReadAgain() throws {
        let fixture = try Self.makeFixture()
        let week = GeoContext.week(of: Self.taken)
        let sighting = try fixture.named(Self.allens)
        #expect(sighting.rarity == RaritySnapshot(occurrence: 0.75, label: .common, calibrationVersion: 7, week: week))

        #expect(fixture.edits.changeBird(of: sighting, to: Self.finch))

        #expect(sighting.rarity == RaritySnapshot(occurrence: 0.25, label: .rare, calibrationVersion: 7, week: week), "the House Finch's there, that week")
        let here = GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)
        #expect(fixture.prior.asked == [here, here], "asked once at the add and once at the change, where and when the photo was taken, not now")

        #expect(fixture.edits.changeBird(of: sighting, to: Self.hermit))
        #expect(sighting.rarity == nil, "a bird the geomodel doesn't know has none, and the last bird's is not kept")

        let nowhere = try fixture.named(Self.allens, at: Self.taken.addingTimeInterval(60), location: nil)
        #expect(fixture.edits.changeBird(of: nowhere, to: Self.finch))
        #expect(nowhere.rarity == nil, "no place, no rarity")
    }

    @Test("the caption written for the old bird is not kept")
    func theOldCaptionGoes() throws {
        let fixture = try Self.makeFixture()
        let sighting = try fixture.named(Self.allens)
        sighting.caption = CardCaption(text: "At the feeder, the small flame held its place.", generatorVersion: "fm-1")
        try fixture.album.mainContext.save()

        #expect(fixture.edits.changeBird(of: sighting, to: Self.finch))

        #expect(try ModelContext(fixture.album).fetch(Sighting.newestFirst()).first?.caption == nil, "gone from the album, not only from memory")
        #expect(CaptionText.front(caption: sighting.caption, tagline: "The street's red singer.") == "The street's red singer.", "its page falls back to the new bird's tagline")
    }

    @Test("a heard sighting's bird can't be changed, and choosing the bird it already is changes nothing")
    func onlyANamingOfTheBirdersOwn() throws {
        let fixture = try Self.makeFixture()
        let heard = try fixture.ledger.add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.taken, location: Self.losFeliz, frame: nil, source: .phone)
        let sighting = try #require(fixture.stored.first { $0.identifier == heard.identifier })
        sighting.caption = CardCaption(text: "From the wire, the red singer.", generatorVersion: "fm-1")
        let rarity = sighting.rarity

        #expect(!fixture.edits.changeBird(of: sighting, to: Self.allens), "BirdNET heard it: its name is not the birder's to change")
        #expect(sighting.speciesID == "Haemorhous mexicanus_House Finch")
        #expect(sighting.rarity == rarity && sighting.caption != nil)

        // Heard, then marked Seen on its page: still a bird BirdNET named.
        fixture.edits.setMethod(.seen, on: sighting)
        #expect(!fixture.edits.changeBird(of: sighting, to: Self.allens))
        #expect(sighting.speciesID == "Haemorhous mexicanus_House Finch")

        let named = try fixture.named(Self.allens, at: Self.taken.addingTimeInterval(60))
        named.caption = CardCaption(text: "At the feeder, the small flame held its place.", generatorVersion: "fm-1")
        let asked = fixture.prior.asked.count
        #expect(fixture.edits.changeBird(of: named, to: Self.allens), "nothing to do is not a failure")
        #expect(named.caption != nil, "the same bird keeps its caption")
        #expect(fixture.prior.asked.count == asked, "and its rarity is not read again")
    }
}
