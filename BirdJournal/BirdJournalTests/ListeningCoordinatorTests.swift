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

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
    }

    static func makeHarness() throws -> Harness {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = URL.temporaryDirectory.appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let recorder = SightingRecorder(container: album, frames: FrameStore(directory: frames))
        let sightings = RunSightings(recorder: recorder)
        let source = ManualAudioSource()
        let phone = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { source },
            location: ScriptedLocationProvider([ListeningSessionTests.newYork])  // away from Los Angeles, so the jay is admitted too
        )
        let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
        let defaults = UserDefaults(suiteName: "coordinator-tests-\(UUID().uuidString)")!
        let run = ListeningCoordinator(phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone, defaults: defaults)
        return Harness(album: album, frames: frames, source: source, run: run, sightings: sightings)
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
        #expect(addition.wasNew)
        #expect(run.isAdded(finch))
        #expect(run.summary == "2 species heard · 1 added")
        #expect(run.acknowledgment?.text == "Added to your journal")
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

    @Test("adding the same species twice in a run updates its sighting instead of adding a second, and undoing that puts the first back")
    func repeatAddUpdates() async throws {
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

        #expect(first.wasNew && !again.wasNew)
        #expect(again.sightingID == first.sightingID)
        #expect(harness.stored.count == 1)
        #expect(run.acknowledgment?.text == "Journal entry updated")
        #expect(run.sightings.entries.count == 1)

        run.undo(again)
        #expect(harness.stored.count == 1, "the first add stands")
        #expect(run.isAdded(jay))

        await run.stop()
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

        #expect(run.state == .ended(.failed("Microphone access was not granted. Allow it in Settings > BirdJournal.")))
        #expect(!run.isReviewing, "nothing was heard, so there is nothing to review")
        await run.stop()
        #expect(run.state == .ended(.failed("Microphone access was not granted. Allow it in Settings > BirdJournal.")))
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

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw ListeningSessionTests.TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
