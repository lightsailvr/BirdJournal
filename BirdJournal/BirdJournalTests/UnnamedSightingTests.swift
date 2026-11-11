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

    // MARK: - On a run, and after it

    @Test("on a run the shutter writes the photo at the run's place, from the phone, with nothing announced; naming it is an add like any other, at the photo's own time and place; Undo leaves the photo waiting, and a delete removes it")
    func captureAndNameOnARun() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        try await waitUntil("the run has its place") { run.coordinate != nil }
        let place = try #require(run.coordinate)
        let photo = CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: Date.now.addingTimeInterval(-90))
        func captures() -> [Capture] { (try? harness.album.mainContext.fetch(Capture.newestFirst())) ?? [] }
        func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: harness.frames.path(percentEncoded: false))) ?? [] }

        let unnamed = try #require(run.capture(photo))

        #expect(unnamed.takenAt == photo.takenAt)
        #expect(unnamed.location == place, "the run's place at the shutter")
        #expect(unnamed.source == .phone)
        #expect(run.sightings.unnamed == [unnamed])
        #expect(captures().map(\.identifier) == [unnamed.id], "in the album before any name")
        #expect(harness.stored.isEmpty)
        #expect(run.reveal == nil && run.acknowledgment == nil, "nothing has been added yet")

        let addition = try #require(run.name(unnamed, as: SeenSightingTests.finch))

        let sighting = try #require(harness.stored.first)
        #expect(sighting.confirmedAt == photo.takenAt)
        #expect(sighting.location == place)
        #expect(sighting.rarity?.label == .rare, "read for the capture's place: \(String(describing: sighting.rarity))")
        #expect(addition.sewsPatch)
        #expect(run.reveal?.addition == addition, "the stitch-in's page")
        #expect(run.acknowledgment?.text == "Your first House Finch")
        #expect(run.acknowledgment?.undo == addition)
        #expect(run.sightings.unnamed.isEmpty)
        #expect(run.sightings.seen.map(\.commonName) == ["House Finch"])
        #expect(captures().isEmpty)

        run.undo(addition)
        #expect(harness.stored.isEmpty)
        #expect(run.reveal == nil && run.acknowledgment == nil)
        let waiting = try #require(run.sightings.unnamed.first)
        #expect(waiting.photoPath == unnamed.photoPath && waiting.takenAt == photo.takenAt && waiting.location == place, "Undo takes the name back; the photo waits again")
        #expect(files() == [unnamed.photoPath])

        #expect(run.delete(waiting))
        #expect(run.sightings.unnamed.isEmpty)
        #expect(captures().isEmpty)
        #expect(files().isEmpty, "the photo went with it: \(files())")

        await run.stop()
    }

    @Test("a capture named after its run has ended follows the rule for an add made on the phone: the stitch-in's page opens at the add, with Undo, and nothing is held for later; the sighting has the photo's time, not the run's end")
    func namedAfterTheRunHasEnded() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        try await waitUntil("the run has its place") { run.coordinate != nil }
        let place = try #require(run.coordinate)
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let photo = CapturedPhoto(data: Data([1]), takenAt: Date.now.addingTimeInterval(-30))
        let unnamed = try #require(run.capture(photo))
        await run.stop()
        #expect(run.isReviewing)
        #expect(run.sightings.unnamed == [unnamed], "it waits in the run's review")
        let endedAt = try #require(run.endedAt)

        let addition = try #require(run.name(unnamed, as: SeenSightingTests.allens))

        #expect(addition.sewsPatch)
        let reveal = try #require(run.reveal, "the page opens at the add")
        #expect(reveal.addition == addition)
        #expect(!reveal.isFromGlasses && !reveal.hasPlayed, "played now, on the phone")
        #expect(run.pendingCeremonies.isEmpty, "nothing waits for later")
        #expect(run.acknowledgment?.undo == addition)
        let sighting = try #require(harness.stored.first)
        #expect(sighting.confirmedAt == photo.takenAt, "the photo's time")
        #expect(sighting.confirmedAt < endedAt)
        #expect(sighting.location == place)
        run.finishCeremony()
        #expect(run.acknowledgment?.undo == addition, "Undo starts again once the stitch-in is over")
        run.dismissReveal()
        #expect(run.sightings.identifiers == [addition.identifier], "the recap counts its patch")
        #expect(run.sightings.seen.map(\.identifier) == [addition.identifier])
    }

    @Test("a run's unnamed sightings come back with its review after the app was killed and are named there; with no run at all, one is named from the album the same way")
    func unnamedOutliveTheApp() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let first = try #require(run.capture(CapturedPhoto(data: Data([1]), takenAt: Date.now.addingTimeInterval(-60))))
        let second = try #require(run.capture(CapturedPhoto(data: Data([2]), takenAt: Date.now.addingTimeInterval(-30))))
        await run.stop()
        #expect(run.isReviewing)

        let relaunched = harness.relaunched()
        #expect(relaunched.isReviewing)
        #expect(relaunched.sightings.unnamed == [first, second], "the review lists them again")
        let addition = try #require(relaunched.name(first, as: SeenSightingTests.allens))
        #expect(relaunched.reveal?.addition == addition)
        #expect(relaunched.sightings.seen.map(\.identifier) == [addition.identifier])
        #expect(relaunched.sightings.unnamed == [second])
        relaunched.dismissReveal()
        relaunched.dismissEnded()

        // A later launch, the review seen and gone: the second still waits in the album, and is named from the Collection.
        let later = harness.relaunched()
        #expect(!later.isReviewing && later.state == .idle)
        #expect(later.sightings.unnamed.isEmpty, "no run, so none of a run's")
        let again = try #require(later.name(second, as: SeenSightingTests.finch))
        #expect(again.sewsPatch)
        #expect(later.reveal?.addition == again, "the phone's rule, with no run at all")
        #expect(later.reveal?.isFromGlasses == false)
        #expect(later.acknowledgment?.undo == again)
        later.finishCeremony()
        #expect(later.acknowledgment?.undo == again, "Undo starts again once the stitch-in is over")
        #expect(later.sightings.seen.isEmpty, "not seen on a run of this launch")
        #expect(harness.stored.map(\.confirmedAt) == [second.takenAt, first.takenAt], "each at its photo's time")

        later.undo(again)
        #expect(harness.stored.count == 1)
        #expect(later.reveal == nil)
        let captures = try harness.album.mainContext.fetch(Capture.newestFirst())
        #expect(captures.map(\.photoPath) == [second.photoPath], "back in the album, waiting")
    }

    @Test("a run that heard nothing and took a photo still has its page when it ends, until the photo is named or deleted")
    func aRunOfOnlyAPhotoKeepsItsPage() async throws {
        let harness = try ListeningCoordinatorTests.makeHarness()
        let run = harness.run
        await run.start()
        #expect(!run.lastRunHasSomething)
        let unnamed = try #require(run.capture(CapturedPhoto(data: Data([1]), takenAt: .now)))
        await run.stop()

        #expect(!run.isReviewing, "no birds heard, so no review")
        #expect(run.lastRunHasSomething, "the photo still to name")
        #expect(run.delete(unnamed))
        #expect(!run.lastRunHasSomething)
    }

    // MARK: - Words

    @Test("an unnamed sighting's row says whose photo it is and when it was taken: minutes within the hour, then the time of day, then the day")
    func rowWords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let locale = Locale(identifier: "en_US")
        // Noon on 15 January 2027 in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 12 * 3_600)
        func row(_ secondsAgo: TimeInterval) -> [String] {
            UnnamedSightingText.row(takenAt: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale).map { $0.replacing("\u{202F}", with: " ") }
        }

        #expect(UnnamedSightingText.title == "Unnamed sighting")
        #expect(row(20) == ["Your photo", "just now"])
        #expect(row(125) == ["Your photo", "2 min ago"])
        #expect(row(59 * 60) == ["Your photo", "59 min ago"])
        #expect(row(2 * 3_600) == ["Your photo", "Today, 10:00 AM"])
        #expect(row(3 * 86_400) == ["Your photo", "Jan 12"], "another day this year: the day, short enough to sit beside Name it")
        #expect(row(30 * 86_400) == ["Your photo", "Dec 16, 2026"], "another year says which")
        #expect(NameBirdText.line(row(125)) == "Your photo · 2 min ago")
        #expect(UnnamedSightingText.spoken(takenAt: now.addingTimeInterval(-125), now: now, calendar: calendar, locale: locale) == "Unnamed sighting, Your photo, 2 min ago, Name it", "one sentence, no middle dot")
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
