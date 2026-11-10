import Album
import Foundation
import Identification
import Pack
import SwiftData
import Testing
import UIKit
@testable import BirdJournal

// Issue #186 (of #185): a bird that is seen and not heard. The birder takes a photo and names it, and the named photo is a
// sighting like any other: Seen, with the photo as its original photo, the photo's time, the run's place and the rarity for
// that place and week; it sews its patch or adds to it, is published as a find that says "saw", and can be undone, photo
// and all. It is marked as named by the birder, and nothing shows a match score for it.
@Suite("Seen sightings")
@MainActor
struct SeenSightingTests {
    static let allens = NameableBird(speciesID: "Selasphorus sasin_Allen's Hummingbird", scientificName: "Selasphorus sasin", commonName: "Allen's Hummingbird", isInFieldGuide: true)
    static let finch = NameableBird(speciesID: RunSightingsTests.finch.birdnetLabel, scientificName: "Haemorhous mexicanus", commonName: "House Finch", isInFieldGuide: true)
    static let hermit = NameableBird(speciesID: "Phaethornis superciliosus_Long-tailed Hermit", scientificName: "Phaethornis superciliosus", commonName: "Long-tailed Hermit", isInFieldGuide: false)
    static let losFeliz = SightingRecorderTests.losFeliz
    static let taken = Date(timeIntervalSince1970: 1_800_000_000)
    /// A set of the two birds around Los Feliz.
    static let losAngeles = CardSet(
        id: "us-ca-la", name: "Los Angeles", edition: "Citrus edition",
        species: ["Haemorhous mexicanus", "Selasphorus sasin"],
        regions: SightingRecorderSetTests.losAngeles.regions
    )

    struct Fixture {
        let album: ModelContainer
        let frames: FrameStore
        let ledger: RunSightings
        let prior: ScriptedOccurrence

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
        var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: frames.directory.path(percentEncoded: false))) ?? [] }
    }

    static func makeFixture(sets: [CardSet] = [losAngeles]) throws -> Fixture {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = FrameStore(directory: URL.temporaryDirectory.appending(path: "seen-\(UUID().uuidString)", directoryHint: .isDirectory))
        let prior = ScriptedOccurrence(["Selasphorus sasin": 0.75, "Haemorhous mexicanus": 0.25])
        let recorder = SightingRecorder(container: album, frames: frames, rarity: RarityReader(occurrenceModel: prior, calibration: .forTests))
        recorder.sets = { sets }
        return Fixture(album: album, frames: frames, ledger: RunSightings(recorder: recorder), prior: prior)
    }

    @Test("naming a photo writes a sighting: Seen, named by the birder, the photo as its original photo, the photo's time, the place given and the rarity for that place and week")
    func namedPhotoIsASighting() throws {
        let fixture = try Self.makeFixture()
        let photo = DebugSeeds.frameJPEG()

        let addition = try fixture.ledger.addSeen(Self.allens, photo: photo, takenAt: Self.taken, location: Self.losFeliz, source: .phone)

        let sighting = try #require(fixture.stored.first)
        #expect(fixture.stored.count == 1)
        #expect(sighting.identifier == addition.identifier)
        #expect(sighting.speciesID == "Selasphorus sasin_Allen's Hummingbird")
        #expect(sighting.method == .seen)
        #expect(sighting.namedByBirder)
        #expect(sighting.source == .phone)
        #expect(sighting.confirmedAt == Self.taken, "the capture's time, not the time it was named")
        #expect(sighting.location == Self.losFeliz)
        let week = GeoContext.week(of: Self.taken)
        #expect(sighting.rarity == RaritySnapshot(occurrence: 0.75, label: .common, calibrationVersion: 7, week: week))
        #expect(fixture.prior.asked == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)])

        let original = try #require(CardText.originalPhotoPath(sighting))
        #expect(sighting.attachedPhotoPaths == [original], "the birder's own photo")
        #expect(sighting.frameImagePath == nil, "not a glasses photo")
        #expect(original.hasSuffix(".jpeg"), "what the picture is: \(original)")
        #expect(try Data(contentsOf: fixture.frames.url(for: original)) == photo, "kept as it came")
        #expect(CardText.evidence(sighting) == "Photo attached")
    }

    @Test("a seen bird new to its placement sews its patch, a repeat adds to the count, and a bird outside every set lands in Uncharted")
    func patchesFollow() throws {
        let fixture = try Self.makeFixture()
        func collection() -> CardCollection { CardCollection(sightings: fixture.stored, sets: [Self.losAngeles]) }

        let first = try fixture.ledger.addSeen(Self.allens, photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .phone)
        #expect(first.sewsPatch)
        #expect(first.patchCount == 1)
        #expect(first.placement.setName == "Los Angeles")
        #expect(first.placement.collectorNumber == "002/002")
        #expect(first.species.commonName == "Allen's Hummingbird")
        #expect(collection().progress(of: "us-ca-la").collected == 1, "the set's progress moves")

        let again = try fixture.ledger.addSeen(Self.allens, photo: Data([2]), takenAt: Self.taken.addingTimeInterval(60), location: Self.losFeliz, source: .phone)
        #expect(!again.sewsPatch)
        #expect(again.patchCount == 2)
        #expect(collection().patch(of: again.identifier)?.count == 2)
        #expect(collection().progress(of: "us-ca-la").collected == 1)

        let uncharted = try fixture.ledger.addSeen(Self.hermit, photo: Data([3]), takenAt: Self.taken.addingTimeInterval(120), location: Self.losFeliz, source: .phone)
        #expect(uncharted.placement == .uncharted, "no set lists it")
        #expect(uncharted.sewsPatch)
        #expect(collection().unchartedSpeciesCount == 1)

        let nowhere = try fixture.ledger.addSeen(Self.allens, photo: Data([4]), takenAt: Self.taken.addingTimeInterval(180), location: nil, source: .phone)
        #expect(nowhere.placement == .uncharted, "no place, as for a heard bird")
        #expect(fixture.stored.first?.rarity == nil)
    }

    @Test("a bird heard and then seen is one patch: the seen sighting adds to the heard one's count")
    func heardAndSeenShareAPatch() throws {
        let fixture = try Self.makeFixture()
        let heard = try fixture.ledger.add(RunSightingsTests.candidate(score: 0.5), confirmedAt: Self.taken, location: Self.losFeliz, frame: nil, source: .phone)
        let seen = try fixture.ledger.addSeen(Self.finch, photo: Data([1]), takenAt: Self.taken.addingTimeInterval(60), location: Self.losFeliz, source: .phone)

        #expect(heard.sewsPatch)
        #expect(!seen.sewsPatch)
        #expect(seen.patchCount == 2)
        #expect(fixture.ledger.entries.map(\.identifier) == [heard.identifier], "the adds of birds heard")
        #expect(fixture.ledger.seen.map(\.identifier) == [seen.identifier], "the birds seen")
        #expect(fixture.ledger.identifiers == [heard.identifier, seen.identifier], "every sighting of the run, in add order")
        #expect(fixture.stored.map(\.namedByBirder) == [true, false])
    }

    @Test("the run lists a seen bird with its name, its time and its photo; Undo removes the sighting and its photo, and only that one")
    func undoRemovesTheSightingAndItsPhoto() throws {
        let fixture = try Self.makeFixture()
        let first = try fixture.ledger.addSeen(Self.allens, photo: Data([1]), takenAt: Self.taken, location: Self.losFeliz, source: .phone)
        let second = try fixture.ledger.addSeen(Self.finch, photo: Data([2]), takenAt: Self.taken.addingTimeInterval(60), location: Self.losFeliz, source: .phone)

        #expect(fixture.ledger.seen.map(\.commonName) == ["Allen's Hummingbird", "House Finch"])
        #expect(fixture.ledger.seen.map(\.scientificName) == ["Selasphorus sasin", "Haemorhous mexicanus"])
        #expect(fixture.ledger.seen.map(\.seenAt) == [Self.taken, Self.taken.addingTimeInterval(60)])
        let firstPhoto = try #require(fixture.ledger.seen.first?.photoPath)
        #expect(fixture.files.count == 2)

        try fixture.ledger.undo(first)
        #expect(fixture.stored.map(\.identifier) == [second.identifier])
        #expect(fixture.ledger.seen.map(\.identifier) == [second.identifier])
        #expect(fixture.ledger.identifiers == [second.identifier])
        #expect(fixture.files.count == 1)
        #expect(!fixture.files.contains(firstPhoto), "the photo goes with the sighting")

        try fixture.ledger.undo(first)
        try fixture.ledger.undo(second)
        #expect(fixture.stored.isEmpty)
        #expect(fixture.ledger.seen.isEmpty)
        #expect(fixture.files.isEmpty)

        try fixture.ledger.addSeen(Self.allens, photo: Data([3]), takenAt: Self.taken, location: nil, source: .phone)
        fixture.ledger.reset()
        #expect(fixture.ledger.seen.isEmpty && fixture.ledger.identifiers.isEmpty, "a new run starts with none; the album keeps the sighting")
        #expect(fixture.stored.count == 1)
    }

    @Test("a photo is kept under the extension of what it is, and as .jpg when that can't be told")
    func photoExtension() {
        #expect(SightingRecorder.pathExtension(of: DebugSeeds.frameJPEG()) == "jpeg")
        #expect(SightingRecorder.pathExtension(of: Data([1, 2, 3])) == "jpg")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        #expect(SightingRecorder.pathExtension(of: png) == "png")
    }

    // MARK: - On a run

    @Test("on a run a seen bird is an add like any other: the capture's time, the run's place, the reveal of a new patch, the acknowledgment with Undo, and Undo takes it all back")
    func addOnARun() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        try await waitUntil("the run has its place") { run.coordinate != nil }
        let place = try #require(run.coordinate)
        let photo = CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: Date.now.addingTimeInterval(-90))

        let addition = try #require(run.addSeen(Self.finch, photo: photo))

        let sighting = try #require(harness.stored.first)
        #expect(sighting.method == .seen && sighting.namedByBirder)
        #expect(sighting.confirmedAt == photo.takenAt)
        #expect(sighting.location == place)
        #expect(sighting.source == .phone)
        #expect(sighting.rarity?.label == .rare, "read for the run's place: \(String(describing: sighting.rarity))")
        #expect(addition.sewsPatch)
        #expect(run.reveal?.addition == addition, "the stitch-in's page")
        #expect(run.reveal?.title == "Your first House Finch")
        #expect(run.acknowledgment?.text == "Your first House Finch")
        #expect(run.acknowledgment?.undo == addition)
        #expect(run.sightings.seen.map(\.commonName) == ["House Finch"])
        #expect(!run.isAdded(RunSightingsTests.candidate(score: 0.5)), "seeing a bird doesn't mark the one heard as added")
        run.finishCeremony()
        #expect(run.acknowledgment?.undo == addition, "Undo starts again once the stitch-in is over")
        run.dismissReveal()

        let again = try #require(run.addSeen(Self.finch, photo: CapturedPhoto(data: Data([9]), takenAt: .now)))
        #expect(!again.sewsPatch)
        #expect(run.reveal == nil, "a repeat has no ceremony")
        #expect(run.acknowledgment?.text == "House Finch seen again, 2 times")
        #expect(run.acknowledgment?.ticksFrom == "House Finch seen again, 1 time")

        run.undo(again)
        #expect(harness.stored.map(\.identifier) == [addition.identifier])
        #expect(run.acknowledgment == nil)
        run.undo(addition)
        #expect(harness.stored.isEmpty)
        #expect(run.sightings.seen.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: harness.frames.path(percentEncoded: false))) ?? []
        #expect(files.isEmpty, "the photos went with them: \(files)")

        await run.stop()
    }

    @Test("a run's seen birds come back with its review after the app was killed, and Undo still works on them")
    func seenBirdsOutliveTheApp() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let addition = try #require(run.addSeen(Self.allens, photo: CapturedPhoto(data: Data([1]), takenAt: .now)))
        run.dismissReveal()
        await run.stop()
        #expect(run.isReviewing)

        let relaunched = harness.relaunched()
        #expect(relaunched.isReviewing)
        #expect(relaunched.sightings.seen.map(\.identifier) == [addition.identifier])
        #expect(relaunched.sightings.identifiers == [addition.identifier])
        let restored = RunSightings.Addition(species: addition.species, sightingID: try #require(relaunched.sightings.seen.first?.id), identifier: addition.identifier, sewsPatch: true, patchCount: 1, placement: addition.placement)
        relaunched.undo(restored)
        #expect(harness.stored.isEmpty)
    }

    // MARK: - The find

    @Test("a signed-in, sharing birder's find of a seen bird says saw, and Undo takes the find back")
    func theFindSaysSaw() async throws {
        let fixture = try Self.makeFixture()
        let client = FindRecorder()
        let library = PackLibrary(bundled: nil, storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "seen-packs-\(UUID().uuidString)")), bundledCovers: .none)
        let places = PlaceNames()
        let outbox = FindOutbox(
            account: FakeAccount.session(signedIn: true), client: client, fileURL: nil, sharing: { .automatic },
            payload: { [album = fixture.album] identifier, isNewPatch in
                await FindOutbox.find(of: identifier, isNewPatch: isNewPatch, album: album, packs: library, places: places)
            }
        )
        fixture.ledger.findOutbox = outbox

        // No place, so nothing asks the network for a city.
        let addition = try fixture.ledger.addSeen(Self.allens, photo: Data([1]), takenAt: Self.taken, location: nil, source: .phone)
        await outbox.flush()

        let find = try #require(client.puts[addition.identifier])
        #expect(find.method == .seen)
        #expect(find.commonName == "Allen's Hummingbird")
        #expect(find.scientificName == "Selasphorus sasin")
        #expect(find.newPatch)
        #expect(find.foundAt == FindPolicy.minute(Self.taken))
        let wire = try #require(String(data: JSONEncoder().encode(find), encoding: .utf8))
        #expect(wire.contains(#""method":"seen""#), "what the feed reads as saw: \(wire)")
        var item = FindRowTests.item(mine: true, place: nil)
        item.method = find.method
        #expect(FindRow.seenAgainLine(item).hasPrefix("You saw a Black Phoebe again, "), "\(FindRow.seenAgainLine(item))")

        try fixture.ledger.undo(addition)
        await outbox.flush()
        #expect(client.puts[addition.identifier] == nil)
        #expect(client.calls == ["put \(addition.identifier)", "delete \(addition.identifier)"])
    }

    // MARK: - No match score

    @Test("a sighting the birder named says how it was met without a microphone, and has no match score to show")
    func noMatchScore() throws {
        let named = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0, source: .phone, method: .seen, namedByBirder: true)
        let fromGlasses = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0, source: .glasses, method: .seen, namedByBirder: true)
        let heard = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0.82, source: .phone)
        let heardThenSeen = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0.82, source: .glasses, method: .seen)

        #expect(CardText.how(named) == "Seen, photographed with iPhone")
        #expect(CardText.how(fromGlasses) == "Seen, photographed with Ray-Ban Display")
        #expect(CardText.how(heard) == "Heard with iPhone microphone")
        #expect(CardText.how(heardThenSeen) == "Seen, and heard with Ray-Ban Display")

        #expect(CardText.matchScore(named) == nil)
        #expect(CardText.matchScore(heard) == "0.82")
        #expect(CardText.identification(named) == "You named this bird from your photo. BirdNET did not hear it, so there is no match score.")
        #expect(CardText.identification(heard).hasPrefix("BirdNET's best single-window score"))
    }

    @Test("a share of a sighting the birder named credits no listening and no BirdNET match")
    func shareHasNoMatch() throws {
        let named = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0, source: .phone, method: .seen, namedByBirder: true)
        let heard = Sighting(speciesID: Self.allens.speciesID, confirmedAt: Self.taken, soundConfidence: 0.82, source: .phone)

        let seenText = SharePolicy.text(for: SharePolicy.content(for: named, commonName: "Allen's Hummingbird", reference: nil, area: "Los Angeles", choices: .init()))
        #expect(seenText.contains("Seen with Featherguild."))
        #expect(!seenText.contains("Heard") && !seenText.contains("BirdNET"), "\(seenText)")
        #expect(!seenText.localizedCaseInsensitiveContains("score") && !seenText.contains("0."), "\(seenText)")

        let heardText = SharePolicy.text(for: SharePolicy.content(for: heard, commonName: "Allen's Hummingbird", reference: nil, area: "Los Angeles", choices: .init()))
        #expect(heardText.contains(SharePolicy.appCredit), "a heard sighting's share is as it was")
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
