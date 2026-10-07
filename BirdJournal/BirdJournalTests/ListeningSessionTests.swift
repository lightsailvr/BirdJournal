import Album
import Foundation
import Identification
import MWDATCore
import Synchronization
import Testing
@testable import BirdJournal

// Issue #6: listening on the phone with no glasses. Audio, location and the models are doubles at their seams
// (`AudioSource`, `LocationProvider`, `BirdModel` + `SpeciesOccurrenceModel`); the session under test is real.
@Suite("Listening session")
struct ListeningSessionTests {
    static let losAngeles = LocationFix.fix(latitude: 34.05, longitude: -118.25, accuracy: 12, at: Date(timeIntervalSince1970: 1_790_000_000))
    static let newYork = LocationFix.fix(latitude: 40.7, longitude: -74, accuracy: 30, at: Date(timeIntervalSince1970: 1_790_000_600))

    @Test("location denied: the screen shows the no-location state, the prior is never asked, and candidates still appear")
    func deniedLocationStillIdentifies() async throws {
        let prior = SpyOccurrence()
        let source = ManualAudioSource()
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: prior) },
            makeSource: { source },
            location: ScriptedLocationProvider([.denied])
        )

        await session.start()
        #expect(session.phase == .listening)
        #expect(session.locationState == .settled(.denied))
        #expect(session.coordinate == nil)

        source.feed(seconds: 4.5)  // windows at 0 and 1.5 s: finch and jay heard twice; no prior rules the jay out
        try await waitUntil("rows appear") { session.list.rows.count == 2 }
        #expect(session.list.rows.map(\.species.commonName) == ["House Finch", "Blue Jay"])
        #expect(session.stack.count == 2)
        #expect(prior.asked.withLock { $0 }.isEmpty)

        await session.stop()
        #expect(session.phase == .idle)
        #expect(source.isStopped)
    }

    @Test("the first fix settles Start; a later fix on the stream updates the coordinate the next add records (issue #44)")
    func laterFixesUpdateTheCoordinate() async throws {
        let source = ManualAudioSource()
        let location = ScriptedLocationProvider([Self.losAngeles])
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { source },
            location: location
        )

        await session.start()
        #expect(session.phase == .listening)
        #expect(session.locationState == .settled(Self.losAngeles))
        #expect(session.coordinate == Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12))
        #expect(session.locationFixedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(location.streamsOpened == 1)

        location.send(Self.newYork)
        try await waitUntil("the new fix shows") { session.locationState == .settled(Self.newYork) }
        #expect(session.coordinate == Coordinate(latitude: 40.7, longitude: -74, accuracy: 30))
        #expect(session.locationFixedAt == Date(timeIntervalSince1970: 1_790_000_600))

        await session.stop()
        #expect(location.isStreaming == false, "Stop closes the location stream, so the blue indicator goes")
    }

    @Test("the engine's geo filter moves coarsely: a fix 100 m away leaves it alone, one 6 km away updates it (issue #44)")
    func geoContextMovesCoarsely() async throws {
        let prior = SpyOccurrence()
        let source = ManualAudioSource()
        let location = ScriptedLocationProvider([Self.losAngeles])
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: prior) },
            makeSource: { source },
            location: location
        )

        await session.start()
        source.feed(seconds: 3)
        try await waitUntil("a window is scored") { session.windowsScored >= 1 }
        #expect(prior.asked.withLock { $0.map(\.latitude) } == [34.05])

        // About 100 m north: the coordinate the next add records moves, the filter does not.
        let nearby = LocationFix.fix(latitude: 34.0509, longitude: -118.25, accuracy: 10, at: Date(timeIntervalSince1970: 1_790_000_060))
        location.send(nearby)
        try await waitUntil("the nearby fix shows") { session.locationState == .settled(nearby) }
        source.feed(seconds: 1.5)
        try await waitUntil("another window is scored") { session.windowsScored >= 2 }
        #expect(prior.asked.withLock { $0.map(\.latitude) } == [34.05])

        // About 6 km north: the filter follows.
        let farther = LocationFix.fix(latitude: 34.104, longitude: -118.25, accuracy: 10, at: Date(timeIntervalSince1970: 1_790_000_120))
        location.send(farther)
        try await waitUntil("the farther fix shows") { session.locationState == .settled(farther) }
        source.feed(seconds: 1.5)
        try await waitUntil("a window is scored at the new place") { prior.asked.withLock { $0.count } >= 2 }
        #expect(prior.asked.withLock { $0.map(\.latitude) } == [34.05, 34.104])

        await session.stop()
    }

    @Test("no fix in time settles Start as unavailable, and a fix that arrives later still filters the next window (issue #44)")
    func unavailableThenFix() async throws {
        let prior = SpyOccurrence()
        let source = ManualAudioSource()
        let location = ScriptedLocationProvider([.unavailable])
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: prior) },
            makeSource: { source },
            location: location
        )

        await session.start()
        #expect(session.phase == .listening)
        #expect(session.locationState == .settled(.unavailable))
        #expect(session.coordinate == nil)

        location.send(Self.newYork)
        try await waitUntil("the fix shows") { session.locationState == .settled(Self.newYork) }
        source.feed(seconds: 3)
        try await waitUntil("a window is scored") { session.windowsScored >= 1 }
        #expect(prior.asked.withLock { $0.map(\.latitude) } == [40.7])

        await session.stop()
    }

    @Test("every new stack is handed on, so the lens can follow it (issue #9)")
    func stacksAreHandedOn() async throws {
        let source = ManualAudioSource()
        let handed = Mutex<[Int]>([])
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            location: ScriptedLocationProvider([.denied]),
            onStack: { stack in handed.withLock { $0.append(stack.count) } }
        )

        await session.start(source: source)
        source.feed(seconds: 4.5)
        try await waitUntil("the stack is handed on") { handed.withLock { $0 }.last == 2 }
        #expect(handed.withLock { $0 } == [2])

        await session.stop()
    }

    @Test("a reference clip played mid-run neither adds a species nor boosts one already heard (issue #41)")
    func playbackIsNotHeard() async throws {
        let source = ManualAudioSource()
        let suppression = AudioSuppression(tail: .zero)
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: LoudBirdModel(), occurrenceModel: SpyOccurrence()) },
            location: ScriptedLocationProvider([Self.losAngeles]),
            suppression: suppression
        )

        await session.start(source: source)
        source.feed(seconds: 4.5, amplitude: 0.5)  // a finch calls: windows at 0, 1.5 and 3 s hear it
        source.feed(seconds: 1.5)
        try await waitUntil("three windows are scored") { session.windowsScored == 3 }
        let heard = try #require(session.stack.candidates.first)
        #expect(heard.species.commonName == "House Finch")
        #expect(heard.windowsAboveThreshold == 3)

        suppression.begin()  // the birder plays the finch's song, and the microphone hears it
        source.feed(seconds: 6, amplitude: 0.5)
        try await waitUntil("the clip's windows are scored") { session.windowsScored == 7 }  // 4.5 to 9 s
        suppression.end()
        source.feed(seconds: 3)
        try await waitUntil("the windows after it are scored") { session.windowsScored == 9 }

        #expect(session.stack.candidates.map(\.species.commonName) == ["House Finch"])
        #expect(session.stack.candidates.first?.windowsAboveThreshold == 3, "the clip did not count as hearing the finch again")
        #expect(session.stack.candidates.first?.score == heard.score)

        await session.stop()
        #expect(source.isStopped)
    }

    @Test("a source that cannot start leaves the session idle with the error shown")
    func sourceFailureIsReported() async {
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: SpyOccurrence()) },
            makeSource: { FailingAudioSource() },
            location: ScriptedLocationProvider([Self.losAngeles])
        )

        await session.start()

        #expect(session.phase == .idle)
        #expect(session.errorMessage == "Microphone access was not granted. Allow it in Settings > BirdJournal.")
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw TimedOut(what: what) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    struct TimedOut: Error { let what: String }
}

// MARK: - Doubles

/// Finch and jay heard loud in every window; robin never.
nonisolated struct ScriptedBirdModel: BirdModel {
    let species = [
        Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"),
        Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves"),
        Species(index: 2, scientificName: "Turdus migratorius", commonName: "American Robin", taxonomicClass: "Aves"),
    ]
    let sampleRate = 32_000
    func scores(for samples: [Float]) throws -> [Float] { [0.9, 0.9, 0] }
}

/// The finch whenever a window has any loud sample in it; nothing in silence.
nonisolated struct LoudBirdModel: BirdModel {
    let species = ScriptedBirdModel().species
    let sampleRate = 32_000
    func scores(for samples: [Float]) throws -> [Float] { [samples.contains { abs($0) > 0.1 } ? 0.9 : 0, 0, 0] }
}

/// Allows the finch everywhere and the jay only away from Los Angeles; records every context it was asked about.
nonisolated final class SpyOccurrence: SpeciesOccurrenceModel {
    let asked = Mutex<[GeoContext]>([])
    func occurrence(in context: GeoContext) throws -> [String: Float] {
        asked.withLock { $0.append(context) }
        return ["Haemorhous mexicanus": 1, "Cyanocitta cristata": context.latitude > 35 ? 1 : 0.01]
    }
}

/// Silence fed by the test at the model rate, so windows fall exactly where expected. Stands in for the glasses
/// stream in the run tests (issue #9), with whatever camera frame the test sets, and records the sessions it was
/// suspended from and resumed on (issue #10).
@MainActor
final class ManualAudioSource: FrameKeepingAudioSource {
    let sampleRate = 32_000
    var latestFrame: CameraFrame?
    private(set) var isStopped = false
    private(set) var suspensions = 0
    private(set) var resumedOn: [DeviceSession] = []
    private var fedSeconds = 0.0
    private let stream: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
    }

    func start() async throws -> AsyncStream<AudioChunk> { stream }

    func stop() async {
        isStopped = true
        continuation.finish()
    }

    func suspend() async {
        suspensions += 1
        latestFrame = nil
    }

    func resume(on session: DeviceSession) async throws {
        resumedOn.append(session)
    }

    func feed(seconds: Double, amplitude: Float = 0) {
        let samples = [Float](repeating: amplitude, count: Int(seconds * Double(sampleRate)))
        continuation.yield(AudioChunk(samples: samples, sampleRate: sampleRate, presentationTime: fedSeconds))
        fedSeconds += seconds
    }
}

@MainActor
final class FailingAudioSource: AudioSource {
    func start() async throws -> AsyncStream<AudioChunk> { throw PhoneMicAudioSource.StartError.permissionDenied }
    func stop() async {}
}

/// A location stream the test scripts: the fixes given up front arrive as soon as the stream is opened (the first
/// settles Start), and `send` feeds another while the run is on, as Core Location would on a walk. Each start opens
/// one stream; `isStreaming` says whether the latest is still being read.
final class ScriptedLocationProvider: LocationProvider {
    private let initial: [LocationFix]
    private var continuation: AsyncStream<LocationFix>.Continuation?
    private(set) var streamsOpened = 0
    /// Cleared from the stream's termination, which runs wherever the consumer dropped it.
    private nonisolated final class Flag: Sendable {
        /// Whether the latest stream is still being read.
        let value = Mutex(false)
    }

    private let streaming = Flag()

    var isStreaming: Bool { streaming.value.withLock { $0 } }

    init(_ fixes: [LocationFix]) {
        precondition(!fixes.isEmpty)
        initial = fixes
    }

    func fixes() -> AsyncStream<LocationFix> {
        streamsOpened += 1
        streaming.value.withLock { $0 = true }
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [streaming] _ in streaming.value.withLock { $0 = false } }
        self.continuation = continuation
        for fix in initial { continuation.yield(fix) }
        return stream
    }

    /// Another fix for the run under way.
    func send(_ fix: LocationFix) {
        continuation?.yield(fix)
    }
}
