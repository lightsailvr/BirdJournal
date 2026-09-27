import Album
import Foundation
import Identification
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

    @Test("one fix at start, another after the refresh interval, and the new place filters the next window")
    func locationRefreshes() async throws {
        let prior = SpyOccurrence()
        let source = ManualAudioSource()
        let location = ScriptedLocationProvider([Self.losAngeles, Self.newYork])
        let session = ListeningSession(
            loadEngine: { IdentificationEngine(model: ScriptedBirdModel(), occurrenceModel: prior) },
            makeSource: { source },
            location: location,
            locationRefreshInterval: .milliseconds(50)
        )

        await session.start()
        #expect(session.locationState == .settled(Self.losAngeles))
        #expect(session.coordinate == Coordinate(latitude: 34.05, longitude: -118.25, accuracy: 12))
        #expect(location.requests == 1)

        try await waitUntil("the location refreshes") { location.requests >= 2 }
        try await waitUntil("the new fix shows") { session.locationState == .settled(Self.newYork) }
        source.feed(seconds: 3)
        try await waitUntil("a window is scored") { session.windowsScored >= 1 }
        #expect(prior.asked.withLock { $0.map(\.latitude) } == [34.05, 40.7])

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

/// Allows the finch everywhere and the jay only away from Los Angeles; records every context it was asked about.
nonisolated final class SpyOccurrence: SpeciesOccurrenceModel {
    let asked = Mutex<[GeoContext]>([])
    func occurrence(in context: GeoContext) throws -> [String: Float] {
        asked.withLock { $0.append(context) }
        return ["Haemorhous mexicanus": 1, "Cyanocitta cristata": context.latitude > 35 ? 1 : 0.01]
    }
}

/// Silence fed by the test at the model rate, so windows fall exactly where expected. Stands in for the glasses
/// stream in the run tests (issue #9), with whatever camera frame the test sets.
@MainActor
final class ManualAudioSource: FrameKeepingAudioSource {
    let sampleRate = 32_000
    var latestFrame: CameraFrame?
    private(set) var isStopped = false
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

    func feed(seconds: Double) {
        let samples = [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
        continuation.yield(AudioChunk(samples: samples, sampleRate: sampleRate, presentationTime: fedSeconds))
        fedSeconds += seconds
    }
}

@MainActor
final class FailingAudioSource: AudioSource {
    func start() async throws -> AsyncStream<AudioChunk> { throw PhoneMicAudioSource.StartError.permissionDenied }
    func stop() async {}
}

/// Hands out the scripted fixes in order, repeating the last one, and counts requests.
final class ScriptedLocationProvider: LocationProvider {
    private let fixes: [LocationFix]
    private(set) var requests = 0

    init(_ fixes: [LocationFix]) {
        precondition(!fixes.isEmpty)
        self.fixes = fixes
    }

    func currentFix() async -> LocationFix {
        defer { requests += 1 }
        return fixes[min(requests, fixes.count - 1)]
    }
}
