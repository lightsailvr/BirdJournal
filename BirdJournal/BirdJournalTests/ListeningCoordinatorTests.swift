import Album
import Foundation
import Identification
import SwiftData
import Testing
@testable import BirdJournal

// Issue #28: the Listen tab's run over the phone microphone, the explicit Add to journal with its undo, one sighting
// per species per run, and the review after Stop. Audio, location and the models are doubles at their seams; the
// coordinator, the ledger and the album are real.
@Suite("Listening coordinator")
@MainActor
struct ListeningCoordinatorTests {
    struct Harness {
        let album: ModelContainer
        let frames: URL
        let source: ManualAudioSource
        let run: ListeningCoordinator
        let sightings: RunSightings
        /// The phone run's location stream, fed by the test.
        let location: ScriptedLocationProvider
        /// The geo prior the recorder reads rarity from (issue #52).
        let rarityPrior: ScriptedOccurrence
        let defaults: UserDefaults

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }

        /// The app killed and started again: a new coordinator over what's on disk, the album and the defaults.
        func relaunched() -> ListeningCoordinator {
            let sightings = RunSightings(recorder: self.sightings.recorder)
            let phone = ListeningSession(loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, makeSource: { ManualAudioSource() }, location: ScriptedLocationProvider([.denied]))
            let glasses = GlassesListeningSession(recorder: sightings.recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
            return ListeningCoordinator(phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone, defaults: defaults)
        }
    }

    static func makeHarness() throws -> Harness {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let rarityPrior = ScriptedOccurrence(["Haemorhous mexicanus": 0.25])
        let recorder = SightingRecorder(container: album, frames: FrameStore(directory: frames), rarity: RarityReader(occurrenceModel: rarityPrior, calibration: .forTests))
        let sightings = RunSightings(recorder: recorder)
        let source = ManualAudioSource()
        let location = ScriptedLocationProvider([ListeningSessionTests.newYork])  // away from Los Angeles, so the jay is admitted too
        let phone = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { source },
            location: location
        )
        let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
        let defaults = UserDefaults(suiteName: "coordinator-tests-\(UUID().uuidString)")!
        let run = ListeningCoordinator(phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone, defaults: defaults)
        return Harness(album: album, frames: frames, source: source, run: run, sightings: sightings, location: location, rarityPrior: rarityPrior, defaults: defaults)
    }

    @Test("an add keeps the method chosen on the review sheet, and is Heard otherwise (issue #150)")
    func addKeepsTheChosenMethod() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }

        try #require(await run.add(run.candidates[0], method: .seen))
        try #require(await run.add(run.candidates[1]))
        #expect(harness.stored.filter { $0.method == .seen }.count == 1)
        #expect(harness.stored.filter { $0.method == .heard }.count == 1)

        await run.stop()
    }

    @Test("an add records the latest fix of the run, not the one Start took (issue #44)")
    func addRecordsTheLatestFix() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }

        let aQuarterMileOn = LocationFix.fix(latitude: 40.7036, longitude: -74, accuracy: 8, at: .now)
        harness.location.send(aQuarterMileOn)
        try await waitUntil("the fix shows") { run.locationState == .settled(aQuarterMileOn) }

        try #require(await run.add(run.candidates[0]))
        #expect(harness.stored.first?.location == Coordinate(latitude: 40.7036, longitude: -74, accuracy: 8))

        await run.stop()
    }

    @Test("an add saves the rarity snapshot read at the add's place and week (issue #52)")
    func addSavesTheRaritySnapshot() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let griffithPark = LocationFix.fix(latitude: 34.1365, longitude: -118.2942, accuracy: 15, at: .now)
        harness.location.send(griffithPark)
        try await waitUntil("the fix shows") { run.locationState == .settled(griffithPark) }

        try #require(await run.add(run.candidates[0]))

        let stored = try #require(harness.stored.first)
        let week = GeoContext.week(of: stored.confirmedAt)
        #expect(stored.rarity == RaritySnapshot(occurrence: 0.25, label: .rare, calibrationVersion: RarityCalibration.forTests.version, week: week))
        #expect(harness.rarityPrior.asked == [GeoContext(latitude: 34.1365, longitude: -118.2942, week: week)])
        await run.stop()
    }

    @Test("a phone run hears species in admission order; Add to journal writes one sighting with the run's location and acknowledges with an undo")
    func addAndUndo() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        #expect(run.state == .idle)

        await run.start()
        #expect(run.state == .listening)
        #expect(run.runSource == .phone)
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        #expect(run.candidates.map(\.species.commonName) == ["House Finch", "Blue Jay"])
        #expect(run.summary == "2 species heard · 0 added")
        #expect(harness.stored.isEmpty, "hearing a bird saves nothing")

        let finch = run.candidates[0]
        let addition = try #require(await run.add(finch))
        #expect(run.isAdded(finch))
        #expect(run.summary == "2 species heard · 1 added")
        #expect(run.acknowledgment?.text == "Your first House Finch")
        #expect(run.acknowledgment?.undo == addition)
        let stored = harness.stored
        #expect(stored.map(\.speciesID) == ["Haemorhous mexicanus_House Finch"])
        #expect(stored.first?.source == .phone)
        #expect(stored.first?.location == Coordinate(latitude: 40.7, longitude: -74, accuracy: 30))
        #expect(stored.first?.frameImagePath == nil, "the phone keeps no frame")

        run.undo(addition)
        #expect(!run.isAdded(finch))
        #expect(harness.stored.isEmpty)
        #expect(run.acknowledgment == nil)

        await run.stop()
    }

    @Test("the Listen tab lists calling birds first, newest caller then longest, and nothing is calling once the run ends (issue #42)")
    func callingNowOrder() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        #expect(run.candidates.map(\.species.commonName) == ["House Finch", "Blue Jay"], "the stack keeps admission order")

        // Both were heard in the same window: the jay, admitted second, is the newer caller and heads the list.
        try await waitUntil("both are calling") { run.orderedCandidates.count == 2 && run.orderedCandidates.allSatisfy(run.isCalling) }
        #expect(run.orderedCandidates.map(\.species.commonName) == ["Blue Jay", "House Finch"])
        try await waitUntil("the remembered order catches up") { run.listOrder.callingCount == 2 }

        await run.stop()
        #expect(run.orderedCandidates.map(\.species.commonName) == ["House Finch", "Blue Jay"], "heard in the same window: admission order")
        #expect(!run.orderedCandidates.contains(where: run.isCalling))
        #expect(run.listOrder.callingCount == 0)
    }

    @Test("adding the same species twice in a run adds a second sighting, and undoing that removes only the second")
    func repeatAddAddsAnother() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let jay = run.candidates[1]

        let first = try #require(await run.add(jay))
        harness.source.feed(seconds: 3)
        try await waitUntil("more windows") { run.candidates[1].windowsAboveThreshold >= 4 }
        let again = try #require(await run.add(run.candidates[1]))

        #expect(again.sightingID != first.sightingID)
        #expect(harness.stored.count == 2)
        #expect(run.acknowledgment?.text == "Seen again · 2 times", "no place: the Uncharted patch, seen again")
        #expect(run.sightings.entries.count == 2)
        #expect(run.sightings.count(of: jay.species) == 2)

        run.undo(again)
        #expect(harness.stored.count == 1, "the first add stands")
        #expect(run.isAdded(jay))
        #expect(run.sightings.count(of: jay.species) == 1)

        await run.stop()
    }

    @Test("a run ending under a stitch-in doesn't start it again over the review: the page picks up as finished (issue #135)")
    func runEndsUnderTheCeremony() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        _ = try #require(await run.add(run.candidates[0]))
        #expect(run.reveal?.hasPlayed == false)
        await run.stop()
        #expect(run.isReviewing)
        #expect(run.reveal?.hasPlayed == true)
    }

    @Test("the first add of a species in a place sews its patch, revealed once with its sighting already saved; a repeat add only ticks its count; dismissing never loses the sighting; an undo removes it (issues #51, #132, #135)")
    func patchReveal() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }
        let finch = run.candidates[0]

        let first = try #require(await run.add(finch))
        #expect(first.sewsPatch)
        #expect(first.patchCount == 1)
        let reveal = try #require(run.reveal)
        #expect(reveal.title == "Your first House Finch")
        #expect(reveal.eyebrow == "New patch · Uncharted")
        #expect(run.acknowledgment?.ticksFrom == nil, "a new patch has no count to tick")
        #expect(reveal.addition == first)
        #expect(!reveal.hasPlayed, "the stitch-in is still to come")
        #expect(harness.stored.map(\.identifier) == [first.identifier], "saved before the ceremony starts")

        let window = try #require(run.acknowledgment)
        run.finishCeremony()
        #expect(run.reveal?.hasPlayed == true, "it stays played: the page never stitches it twice")
        #expect(run.reveal?.addition == first)
        let reopened = try #require(run.acknowledgment)
        #expect(reopened.id != window.id, "Undo's window starts again as the page starts offering it")
        #expect(reopened.undo == first)
        #expect(reopened.text == window.text)
        run.finishCeremony()
        #expect(run.acknowledgment?.id == reopened.id, "only once")

        run.dismissReveal()
        #expect(run.reveal == nil)
        #expect(harness.stored.map(\.identifier) == [first.identifier], "dismissing keeps the sighting")

        // The same species again: its count, and nothing that covers the screen or asks for a tap (the maintainer, 2026-11-04).
        let again = try #require(await run.add(finch))
        #expect(!again.sewsPatch)
        #expect(again.patchCount == 2)
        #expect(run.reveal == nil, "a repeat add opens no page")
        #expect(harness.stored.count == 2, "and the sighting is saved")
        #expect(run.acknowledgment?.text == "Seen again · 2 times")
        #expect(run.acknowledgment?.ticksFrom == "Seen again · 1 time", "what it says before it ticks")
        #expect(run.acknowledgment?.undo == again)

        // A first of another species, taken back inside the window: the sighting and its reveal are gone.
        let jay = try #require(await run.add(run.candidates[1]))
        #expect(run.reveal?.addition == jay)
        #expect(run.acknowledgment?.text == "Your first Blue Jay")
        run.undo(jay)
        #expect(run.reveal == nil)
        #expect(!harness.stored.contains { $0.identifier == jay.identifier })
        #expect(harness.stored.count == 2)

        await run.stop()
    }

    // The glasses are about hearing and capturing; the celebration happens on the phone once the run is over (the maintainer,
    // 2026-11-04). The lens's save is called directly here; `MockDeviceKitTests` goes through its real inputs.

    /// A run with both birds heard, ready for the lens to add them.
    private func heardBoth(_ harness: Harness) async throws -> (finch: Candidate, jay: Candidate) {
        await harness.run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { harness.run.candidates.count == 2 }
        return (harness.run.candidates[0], harness.run.candidates[1])
    }

    @Test("a patch sewn from the glasses plays nothing mid-run, and only once the run is over, in the order sewn; a repeat from the glasses plays nothing")
    func ceremonyWaitsForTheRunToEnd() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        let (finch, jay) = try await heardBoth(harness)

        await run.glasses.save(jay, confirmedAt: .now, frame: nil)
        await run.glasses.save(jay, confirmedAt: .now, frame: nil)
        await run.glasses.save(finch, confirmedAt: .now, frame: nil)
        #expect(harness.stored.count == 3)
        #expect(!run.hasCeremonyWaiting, "nothing plays on the phone mid-run")
        run.showNextCeremony()
        #expect(run.reveal == nil)
        #expect(run.acknowledgment == nil, "and no toast: the lens said it")

        await run.stop()
        #expect(run.hasCeremonyWaiting)
        run.showNextCeremony()
        let first = try #require(run.reveal)
        #expect(first.commonName == "Blue Jay", "the order sewn")
        #expect(first.addition.patchCount == 2, "as the album has it now")
        #expect(first.eyebrow == "New patch · Uncharted")
        #expect(!first.hasPlayed)
        #expect(!run.hasCeremonyWaiting, "one at a time")

        run.finishCeremony()
        #expect(run.acknowledgment == nil, "no Undo long after the add: the sighting's page can delete it")
        #expect(run.waitingCeremonies == 1, "the finch's")
        run.dismissReveal()
        #expect(run.reveal?.commonName == "House Finch", "Next moves straight on")
        run.finishCeremony()
        #expect(run.waitingCeremonies == 0)
        run.dismissReveal()
        #expect(run.reveal == nil)
        #expect(!run.hasCeremonyWaiting)
    }

    @Test("a ceremony waits through the app being killed, plays once, and doesn't play again after the next launch")
    func ceremonySurvivesAKill() async throws {
        let harness = try Self.makeHarness()
        let (finch, _) = try await heardBoth(harness)
        await harness.run.glasses.save(finch, confirmedAt: .now, frame: nil)

        // Killed mid-run.
        let next = harness.relaunched()
        #expect(next.state == .idle)
        #expect(next.hasCeremonyWaiting)
        next.showNextCeremony()
        #expect(next.reveal?.commonName == "House Finch")

        // Killed part way through the stitch-in, which never played to its end: it's still owed.
        let third = harness.relaunched()
        #expect(third.hasCeremonyWaiting)
        third.showNextCeremony()
        third.finishCeremony()
        #expect(third.reveal?.hasPlayed == true)

        // Killed on the finished page.
        let fourth = harness.relaunched()
        #expect(!fourth.hasCeremonyWaiting, "plays once")
        fourth.showNextCeremony()
        #expect(fourth.reveal == nil)
    }

    @Test("a sighting deleted while its ceremony waited is skipped, and the next one plays")
    func ceremonyOfADeletedSighting() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        let (finch, jay) = try await heardBoth(harness)
        await run.glasses.save(finch, confirmedAt: .now, frame: nil)
        await run.glasses.save(jay, confirmedAt: .now, frame: nil)
        await run.stop()

        let deleted = try #require(harness.stored.first { $0.commonName == "House Finch" })
        try harness.sightings.recorder.delete(deleted)
        run.showNextCeremony()
        #expect(run.reveal?.commonName == "Blue Jay")
        run.finishCeremony()
        #expect(run.waitingCeremonies == 0, "the deleted one is gone from the queue too")
    }

    @Test("skipping the rest ends the queue for good, and what it skipped stays in the album")
    func skipTheRest() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        let (finch, jay) = try await heardBoth(harness)
        await run.glasses.save(finch, confirmedAt: .now, frame: nil)
        await run.glasses.save(jay, confirmedAt: .now, frame: nil)
        await run.stop()
        run.showNextCeremony()
        run.finishCeremony()
        #expect(run.waitingCeremonies == 1)

        run.skipCeremonies()
        #expect(run.reveal == nil)
        #expect(!run.hasCeremonyWaiting)
        #expect(!harness.relaunched().hasCeremonyWaiting, "not after a launch either")
        #expect(harness.stored.count == 2)
    }

    @Test("a phone add during a run keeps its own ceremony and its Keep listening; the lens's still wait for the end")
    func phoneAddDuringARun() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        let (finch, jay) = try await heardBoth(harness)
        await run.glasses.save(finch, confirmedAt: .now, frame: nil)

        _ = try #require(await run.add(jay))
        #expect(run.reveal?.commonName == "Blue Jay")
        run.finishCeremony()
        #expect(run.acknowledgment?.undo != nil, "a phone add's Undo stays")
        #expect(run.waitingCeremonies == 0, "the run isn't over: this page says Keep listening")
        run.dismissReveal()
        #expect(run.reveal == nil, "nothing mid-run")

        await run.stop()
        run.showNextCeremony()
        #expect(run.reveal?.commonName == "House Finch")
    }

    @Test("a candidate's sheet up holds the next ceremony back: it would play under the sheet")
    func candidateSheetHoldsItBack() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        let (finch, jay) = try await heardBoth(harness)
        await run.glasses.save(finch, confirmedAt: .now, frame: nil)
        run.reviewing = jay
        await run.stop()
        #expect(!run.hasCeremonyWaiting)
        run.reviewing = nil
        #expect(run.hasCeremonyWaiting)
    }

    @Test("Stop keeps the species heard for the review, adding from the review still works, and Done clears the run")
    func stopThenReview() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        harness.source.feed(seconds: 4.5)
        try await waitUntil("candidates appear") { run.candidates.count == 2 }

        await run.stop()

        #expect(run.state == .ended(.stopped))
        #expect(!run.state.isActive)
        #expect(run.isReviewing)
        #expect(run.candidates.count == 2, "the review still lists what was heard")
        #expect(harness.source.isStopped)

        _ = await run.add(run.candidates[0])
        #expect(harness.stored.count == 1)

        run.dismissEnded()
        #expect(run.state == .idle)
        #expect(!run.isReviewing)
    }

    @Test("a run over a source that cannot start ends failed with the reason, and a stop while idle is ignored")
    func failedStart() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let recorder = SightingRecorder(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        let sightings = RunSightings(recorder: recorder)
        let phone = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { FailingAudioSource() },
            location: ScriptedLocationProvider([.denied])
        )
        let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) })
        let run = ListeningCoordinator(phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone, defaults: UserDefaults(suiteName: "coordinator-tests-\(UUID().uuidString)")!)

        await run.start()

        #expect(run.state == .ended(.failed("Microphone access was not granted. Allow it in Settings > Featherguild.")))
        #expect(!run.isReviewing, "nothing was heard, so there is nothing to review")
        await run.stop()
        #expect(run.state == .ended(.failed("Microphone access was not granted. Allow it in Settings > Featherguild.")))
    }

    @Test("the chosen source is remembered, and a phone with no glasses linked starts on the microphone")
    func sourceIsRemembered() throws {
        let harness = try Self.makeHarness()
        #expect(harness.run.source == .phone)
        harness.run.source = .glasses
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let recorder = SightingRecorder(container: album, frames: FrameStore(directory: URL.temporaryDirectory))
        let defaults = UserDefaults(suiteName: "coordinator-tests-remembered-\(UUID().uuidString)")!
        defaults.set("glasses", forKey: "listeningSource")
        let run = ListeningCoordinator(phone: ListeningSession(), glasses: GlassesListeningSession(recorder: recorder), sightings: RunSightings(recorder: recorder), levels: LevelSink(), defaultSource: .phone, defaults: defaults)
        #expect(run.source == .glasses)
    }

    /// Long, since it only bounds a failure: other tests' pixel work and start-up hold the main actor this test polls on for seconds at a time.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw ListeningSessionTests.TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
