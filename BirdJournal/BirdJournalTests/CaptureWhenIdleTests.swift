import Album
import Foundation
import Identification
import SwiftData
import Synchronization
import Testing
@testable import BirdJournal

// Issue #191 (of #185): "Capture a sighting" with no run under way. The photo takes the phone's current place, read while
// the camera is open; it belongs to no run, so naming it is acknowledged on the idle Listen tab and a run started
// afterwards knows nothing of it. Location and the models are doubles at their seams; the coordinator, the ledger and the
// album are real.
@Suite("Capture a sighting when not listening")
@MainActor
struct CaptureWhenIdleTests {
    static let finch = SeenSightingTests.finch
    static let griffith = LocationFix.fix(latitude: 34.1365, longitude: -118.2942, accuracy: 10, at: Date(timeIntervalSince1970: 1_790_000_000))
    static let griffithPlace = Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 10)

    struct Harness {
        let album: ModelContainer
        let frames: URL
        let source: ManualAudioSource
        let run: ListeningCoordinator
        /// The phone run's own location stream.
        let runLocation: ScriptedLocationProvider
        /// What the camera reads where the phone is from, with no run.
        let location: HeldLocationProvider

        var stored: [Sighting] { (try? album.mainContext.fetch(Sighting.newestFirst())) ?? [] }
        var captures: [Capture] { (try? album.mainContext.fetch(Capture.newestFirst())) ?? [] }
    }

    static func makeHarness() throws -> Harness {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let frames = URL.temporaryDirectory.appending(path: "idle-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let recorder = SightingRecorder(container: album, frames: FrameStore(directory: frames), rarity: nil)
        recorder.sets = { [SeenSightingTests.losAngeles] }
        let sightings = RunSightings(recorder: recorder)
        let runLocation = ScriptedLocationProvider([ListeningSessionTests.newYork])
        let source = ManualAudioSource()
        let phone = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { source },
            location: runLocation
        )
        let glasses = GlassesListeningSession(recorder: recorder, sightings: sightings, loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) }, location: ScriptedLocationProvider([.denied]))
        let location = HeldLocationProvider()
        let run = ListeningCoordinator(
            phone: phone, glasses: glasses, sightings: sightings, levels: LevelSink(), defaultSource: .phone,
            defaults: UserDefaults(suiteName: "idle-capture-\(UUID().uuidString)")!, captureLocation: location
        )
        return Harness(album: album, frames: frames, source: source, run: run, runLocation: runLocation, location: location)
    }

    static func photo() -> CapturedPhoto {
        CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: Date.now.addingTimeInterval(-5))
    }

    @Test("with no run the camera reads where the phone is, and the shutter writes the photo there: in the album, on no run's list, with the idle tab still the idle tab")
    func theShutterTakesTheCurrentPlace() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        #expect(!harness.location.isStreaming, "nothing reads the place before the camera opens")

        run.isCapturing = true
        #expect(harness.location.isStreaming, "the camera is open: the place is being read")
        harness.location.send(Self.griffith)
        try await waitUntil("the fix is in") { run.capturePlace != nil }
        #expect(run.capturePlace == Self.griffithPlace)

        let unnamed = try #require(run.capture(Self.photo()))

        #expect(unnamed.location == Self.griffithPlace, "the phone's current place")
        #expect(unnamed.source == .phone)
        #expect(harness.captures.map(\.identifier) == [unnamed.id], "in the album from the shutter on")
        #expect(harness.captures.first?.location == Self.griffithPlace)
        #expect(run.sightings.unnamed.isEmpty, "no run took it")
        #expect(run.state == .idle && !run.showsRun, "the Listen tab stays as it was")
        #expect(run.acknowledgment == nil && run.reveal == nil, "nothing has been added yet")

        run.isCapturing = false
        try await waitUntil("the read ends with the camera") { !harness.location.isStreaming }
        #expect(harness.location.streamsOpened == 1)
        #expect(harness.runLocation.streamsOpened == 0, "no run was started for it")
    }

    @Test("with location refused the photo has no place, the sheet says so, and naming it lands as a sighting without a place does: Uncharted")
    func withLocationRefusedThePlaceIsNotRecorded() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true
        harness.location.send(.denied)
        try await waitUntil("the refusal is in") { run.placeOutsideRun.state == .settled(.denied) }
        #expect(run.capturePlace == nil)

        let unnamed = try #require(run.capture(Self.photo()))
        #expect(unnamed.location == nil)
        #expect(await run.placed(unnamed) == nil, "no place is coming")
        #expect(NameBirdText.place(location: unnamed.location, name: nil) == "Place not recorded", "what the naming sheet says under the photo")

        let addition = try #require(run.name(unnamed, as: Self.finch))
        let sighting = try #require(harness.stored.first)
        #expect(sighting.location == nil)
        #expect(addition.placement.setID == nil, "Uncharted, as any sighting without a place: \(addition.placement)")
        #expect(run.acknowledgment?.text == "Your first House Finch")
    }

    @Test("naming it is an add like any other, acknowledged on the idle tab: a new patch's page at once, Undo in the acknowledgment, and Undo leaves the photo to name")
    func namingIsAnAddOnTheIdleTab() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true
        harness.location.send(Self.griffith)
        try await waitUntil("the fix is in") { run.capturePlace != nil }
        let photo = Self.photo()
        let unnamed = try #require(run.capture(photo))

        let addition = try #require(run.name(unnamed, as: Self.finch))
        run.isCapturing = false

        let sighting = try #require(harness.stored.first)
        #expect(sighting.method == .seen && sighting.namedByBirder)
        #expect(sighting.location == Self.griffithPlace && sighting.confirmedAt == photo.takenAt)
        #expect(sighting.source == .phone)
        #expect(harness.captures.isEmpty, "it is a sighting now")
        #expect(addition.sewsPatch && addition.placement.setID == "us-ca-la")
        #expect(run.reveal?.addition == addition, "the stitch-in plays at the add")
        #expect(run.reveal?.hasPlayed == false)
        #expect(run.acknowledgment?.text == "Your first House Finch in Los Angeles")
        #expect(run.acknowledgment?.undo == addition, "the acknowledgment carries Undo")
        #expect(!run.showsRun && run.state == .idle, "all of it on the idle tab")
        #expect(run.sightings.seen.isEmpty && run.sightings.identifiers.isEmpty, "there is no Seen this run without a run")

        // The stitch-in over, its page closed: Undo is still offered, in the acknowledgment.
        run.finishCeremony()
        run.dismissReveal()
        #expect(run.acknowledgment?.undo == addition)

        run.undo(addition)
        #expect(harness.stored.isEmpty, "the name is taken back")
        #expect(run.acknowledgment == nil && run.reveal == nil)
        let waiting = try #require(harness.captures.first)
        #expect(waiting.photoPath == unnamed.photoPath && waiting.location == Self.griffithPlace && waiting.takenAt == photo.takenAt, "the photo waits again, in To name")
        #expect(run.sightings.unnamed.isEmpty && !run.showsRun, "on no run's list")
    }

    @Test("a run started afterwards is unaffected and counts none of it: its lists start empty, its place is its own, and what it hears is not offered for the earlier photo")
    func aRunStartedAfterwardsKnowsNothingOfIt() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true
        harness.location.send(Self.griffith)
        try await waitUntil("the fix is in") { run.capturePlace != nil }
        let named = try #require(run.capture(Self.photo()))
        try #require(run.name(named, as: Self.finch))
        run.dismissReveal()
        let left = try #require(run.capture(Self.photo()))
        run.isCapturing = false

        await run.start()
        #expect(run.state == .listening)
        #expect(run.showsRun)
        #expect(run.sightings.seen.isEmpty && run.sightings.unnamed.isEmpty && run.sightings.identifiers.isEmpty && run.sightings.entries.isEmpty)
        #expect(run.acknowledgment == nil, "the earlier add's acknowledgment went with Start")
        try await waitUntil("the run has its place") { run.coordinate != nil }
        #expect(run.coordinate != Self.griffithPlace, "the run reads its own place: \(String(describing: run.coordinate))")
        #expect(harness.stored.count == 1 && harness.captures.map(\.identifier) == [left.id], "the album keeps both")

        harness.source.feed(seconds: 4.5)
        try await waitUntil("the run hears its birds") { run.candidates.count == 2 }
        #expect(!run.heardScientificNames.isEmpty)
        #expect(run.heardScientificNames(for: left).isEmpty, "no Heard this run for a photo taken outside it")

        // On the run the camera is the run's again: its place, its list, and nothing read beside it.
        run.isCapturing = true
        #expect(!run.isCapturingOutsideRun)
        let onTheRun = try #require(run.capture(Self.photo()))
        #expect(onTheRun.location == run.coordinate)
        #expect(run.sightings.unnamed == [onTheRun])
        #expect(run.heardScientificNames(for: onTheRun) == run.heardScientificNames)
        run.isCapturing = false
        #expect(harness.location.streamsOpened == 1, "only the idle camera read the place for itself")

        // Naming the earlier photo during the run is an add, and still no part of the run.
        try #require(run.name(left, as: Self.finch))
        #expect(run.sightings.seen.isEmpty && run.sightings.identifiers.isEmpty)
        run.dismissReveal()
        await run.stop()
    }

    @Test("a shutter quicker than the first fix loses nothing: the photo is written at once without a place, and gets it when the fix is in, even with the camera closed by then")
    func aShutterQuickerThanTheFix() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true

        let quick = try #require(run.capture(Self.photo()))
        #expect(quick.location == nil)
        #expect(harness.captures.map(\.identifier) == [quick.id], "written at the shutter, before any fix")
        // "Name it later", before the fix: the camera closes and the read goes on to its first answer.
        run.isCapturing = false
        #expect(harness.location.isStreaming, "still reading, for the photo that waits")

        harness.location.send(Self.griffith)
        let placed = try #require(await run.placed(quick))
        #expect(placed.id == quick.id && placed.location == Self.griffithPlace)
        #expect(placed.photoPath == quick.photoPath && placed.takenAt == quick.takenAt)
        #expect(harness.captures.first?.location == Self.griffithPlace, "in the album")
        try await waitUntil("the read ends once it has answered") { !harness.location.isStreaming }
        #expect(run.capturePlace == nil, "and nothing is kept for the next photo")
    }

    @Test("a photo named before the fix arrives stays as it was named: without a place")
    func namedBeforeTheFix() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true
        let quick = try #require(run.capture(Self.photo()))
        try #require(run.name(quick, as: Self.finch))

        harness.location.send(Self.griffith)
        #expect(await run.placed(quick) == nil, "there is no unnamed sighting to place")
        #expect(harness.stored.first?.location == nil)
        #expect(harness.captures.isEmpty)
        run.isCapturing = false
    }

    @Test("a library photo chosen with no run keeps the place it carries, and one that carries none takes the phone's")
    func aLibraryPhotoKeepsItsOwnPlace() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        run.isCapturing = true
        harness.location.send(Self.griffith)
        try await waitUntil("the fix is in") { run.capturePlace != nil }
        let sanDiego = Coordinate(latitude: 32.7157, longitude: -117.1611, accuracy: 0)

        let carried = try #require(run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: Date(timeIntervalSince1970: 1_780_000_000), place: sanDiego, origin: .library(carriesDate: true))))
        #expect(carried.location == sanDiego)
        let bare = try #require(run.capture(CapturedPhoto(data: DebugSeeds.frameJPEG(), takenAt: .now, origin: .library(carriesDate: false))))
        #expect(bare.location == Self.griffithPlace)
        #expect(run.sightings.unnamed.isEmpty)
        run.isCapturing = false
    }

    @Test("after a run that left nothing the tab is idle again, and a photo taken there is recorded where the phone is now, not where that run was")
    func afterARunThatLeftNothing() async throws {
        let harness = try Self.makeHarness()
        let run = harness.run
        await run.start()
        try await waitUntil("the run has its place") { run.coordinate != nil }
        await run.stop()
        #expect(run.state == .ended(.stopped) && !run.showsRun, "nothing heard: the idle tab")
        #expect(run.coordinate != nil, "the ended run still remembers where it was")

        run.isCapturing = true
        #expect(run.isCapturingOutsideRun)
        harness.location.send(Self.griffith)
        try await waitUntil("the fix is in") { run.capturePlace != nil }
        let unnamed = try #require(run.capture(Self.photo()))
        #expect(unnamed.location == Self.griffithPlace)
        #expect(run.sightings.unnamed.isEmpty && !run.showsRun, "the tab stays idle: the photo is no part of the run that ended")
        run.isCapturing = false
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
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

/// A location stream that says nothing until the test does: each `fixes()` opens one stream, `send` feeds the latest, and
/// `isStreaming` says whether it is still being read.
final class HeldLocationProvider: LocationProvider {
    private var continuation: AsyncStream<LocationFix>.Continuation?
    private(set) var streamsOpened = 0
    private nonisolated final class Flag: Sendable {
        let value = Mutex(false)
    }

    private let streaming = Flag()

    var isStreaming: Bool { streaming.value.withLock { $0 } }

    func fixes() -> AsyncStream<LocationFix> {
        streamsOpened += 1
        streaming.value.withLock { $0 = true }
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [streaming] _ in streaming.value.withLock { $0 = false } }
        self.continuation = continuation
        return stream
    }

    func send(_ fix: LocationFix) {
        continuation?.yield(fix)
    }
}
