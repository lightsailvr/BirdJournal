import Foundation
import Testing
@testable import Identification

// The engine seam from the spec's testing strategy: WAV files in, CandidateStack out. The committed synthetic
// fixture drives a scripted model to prove the pipeline (resample, window, score, admit); the real models run on
// the noise fixture and, when present, on the external labeled clips listed in fixtures/clips.json.
@Suite("IdentificationEngine")
struct IdentificationEngineTests {
    static let la = GeoContext(latitude: 34.05, longitude: -118.25, week: 36)

    @Test("a 44.1 kHz clip is resampled and cut into 3 s windows every 1.5 s, and a species is admitted on its second window")
    func pipelineWithScriptedModel() async throws {
        let model = ScriptedBirdModel(scoresPerWindow: [
            [0.9, 0.9, 0.0],   // finch and jay heard once; jay is not allowed here
            [0.8, 0.9, 0.5],   // finch admitted; robin heard once
            [0.1, 0.9, 0.6],   // robin admitted; finch below threshold this window
        ])
        let engine = IdentificationEngine(
            model: model,
            occurrenceModel: FixedOccurrence(["Haemorhous mexicanus": 1, "Cyanocitta cristata": 0.01, "Turdus migratorius": 0.5]),
            configuration: IdentificationConfiguration()
        )

        let events = try await collect(engine.identify(WAVFileAudioSource(url: try Fixtures.url("synthetic-chirps-44k1.wav")), in: Self.la))

        let windows = events.compactMap { if case .window(let report) = $0 { report } else { nil } }
        #expect(windows.map(\.start) == [0, 1.5, 3])
        #expect(model.windowSampleCounts.withLock { $0 } == [96_000, 96_000, 96_000])

        let stacks = events.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }
        #expect(stacks.count == 2)
        #expect(stacks.last?.candidates.map(\.species.commonName) == ["House Finch", "American Robin"])
        #expect(stacks.last?.candidates.map(\.score) == [0.9, 0.6])
        #expect(stacks.last?.candidates.first?.windowsAboveThreshold == 2)
        #expect(events.last == .stack(stacks.last!))
    }

    @Test("with no location, the prior is never consulted and every bird class can be admitted")
    func noLocationSkipsThePrior() async throws {
        let model = ScriptedBirdModel(scoresPerWindow: [[0.9, 0.9, 0.0], [0.9, 0.9, 0.0]])
        let engine = IdentificationEngine(model: model, occurrenceModel: ThrowingOccurrence())

        let events = try await collect(engine.identify(WAVFileAudioSource(url: try Fixtures.url("synthetic-chirps-44k1.wav")), in: nil))

        let stacks = events.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }
        #expect(stacks.last?.candidates.map(\.species.commonName) == ["House Finch", "Blue Jay"])
    }

    @Test("a location update mid-session applies from the next window: a species the old place ruled out is admitted")
    func locationUpdateMidSession() async throws {
        // Every window hears finch and jay; New York's prior allows both, Los Angeles's only the finch.
        let model = ScriptedBirdModel(scoresPerWindow: Array(repeating: [0.9, 0.9, 0.0], count: 8))
        let prior = OccurrenceByLatitude([
            34: ["Haemorhous mexicanus": 1, "Cyanocitta cristata": 0.01],
            40: ["Haemorhous mexicanus": 1, "Cyanocitta cristata": 1],
        ])
        let engine = IdentificationEngine(model: model, occurrenceModel: prior)
        let source = ManualAudioSource()
        let context = LiveGeoContext(Self.la)

        let events = try await engine.identify(source, in: context)
        source.feed(seconds: 4.5)  // windows at 0 and 1.5 s: finch admitted, jay counted nowhere
        var stacks: [CandidateStack] = []
        for try await event in events {
            guard case .stack(let stack) = event else { continue }
            stacks.append(stack)
            if stacks.count == 1 {
                context.update(GeoContext(latitude: 40.7, longitude: -74, week: 36))
                source.feed(seconds: 3)  // windows at 3 and 4.5 s: jay counted twice, admitted
            } else if stack.count == 2 {
                await source.stop()
            }
        }

        #expect(stacks.map { $0.candidates.map(\.species.commonName) } == [["House Finch"], ["House Finch"], ["House Finch", "Blue Jay"]])
        #expect(stacks.last?.candidate(for: model.species[1])?.admittedAt == 4.5)
        #expect(prior.asked.withLock { $0 } == [34.05, 40.7])
    }

    @Test("a call is admitted within 6 s of audio after it starts, whatever its phase against the 1.5 s hop (issue #6)", arguments: [0.0, 0.7, 1.4, 1.6, 2.2, 2.9, 3.1, 4.4])
    func admittedWithinSixSeconds(callStart: Double) async throws {
        // A model that "hears" the species once at least half a window (1.5 s) is loud.
        var configuration = IdentificationConfiguration()
        configuration.windowThreshold = 0.5
        let engine = IdentificationEngine(model: LoudnessBirdModel(), occurrenceModel: FixedOccurrence(["Haemorhous mexicanus": 1]), configuration: configuration)
        let source = ManualAudioSource()
        source.feed(seconds: callStart)
        source.feed(seconds: 6, amplitude: 0.5)
        source.feed(seconds: 3)
        await source.stop()

        let events = try await collect(engine.identify(source, in: Self.la))

        let stack = try #require(events.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }.last)
        let candidate = try #require(stack.candidates.first)
        let admittingWindowEnds = candidate.admittedAt + configuration.windowDuration
        #expect(admittingWindowEnds - callStart <= 6, "call at \(callStart) s admitted by the window ending at \(admittingWindowEnds) s")
        #expect(admittingWindowEnds - callStart <= 4.5)  // the actual bound: two hops plus one window, minus the call's head start
    }

    @Test("a source that ends before one window yields no windows and no stack")
    func tooShortForAWindow() async throws {
        let engine = IdentificationEngine(model: ScriptedBirdModel(scoresPerWindow: []), occurrenceModel: FixedOccurrence([:]))
        let source = WAVFileAudioSource(url: try Fixtures.url("synthetic-chirps-44k1.wav"))
        var configuration = IdentificationConfiguration()
        configuration.windowDuration = 10
        configuration.hopDuration = 5
        let longWindows = IdentificationEngine(model: engine.model, occurrenceModel: engine.occurrenceModel, configuration: configuration)

        let events = try await collect(longWindows.identify(source, in: Self.la))

        #expect(events.isEmpty)
    }

    @Test("a model failure ends the stream with its error and stops the source")
    func modelErrorPropagates() async throws {
        let engine = IdentificationEngine(model: FailingBirdModel(), occurrenceModel: FixedOccurrence([:]))
        let source = WAVFileAudioSource(url: try Fixtures.url("synthetic-chirps-44k1.wav"))

        await #expect(throws: FailingBirdModel.Failure.self) {
            try await collect(engine.identify(source, in: Self.la))
        }
        _ = try await source.start()  // stopped, so it can start again
        await source.stop()
    }

    @Test("with the real models, the noise clip yields an empty stack and every window is scored")
    func noiseYieldsEmptyStack() async throws {
        let engine = IdentificationEngine(model: try ONNXBirdModel.bundled(), occurrenceModel: try ONNXGeoModel.bundled())

        let events = try await collect(engine.identify(WAVFileAudioSource(url: try Fixtures.url("noise-44k1.wav")), in: Self.la))

        let windows = events.compactMap { if case .window(let report) = $0 { report } else { nil } }
        #expect(windows.map(\.start) == [0, 1.5, 3])
        #expect(windows.allSatisfy { $0.topScore < 0.15 })
        #expect(events.filter { if case .stack = $0 { true } else { false } }.isEmpty)
        // Timing here is informative: package tests are tool-hosted and never run on a device. The 150 ms budget
        // is asserted on the phone by the app-hosted InferenceBudgetTests.
        print("noise clip: slowest window inference \(windows.map(\.inference).max()!)")
    }

    @Test("external labeled clips: the expected species ranks in the top three and filtered species never appear", arguments: ExternalClips.available())
    func externalClip(_ clip: ExternalClip) async throws {
        let model = try ONNXBirdModel.bundled()
        let geo = try ONNXGeoModel.bundled()
        let engine = IdentificationEngine(model: model, occurrenceModel: geo)
        let context = GeoContext(latitude: clip.latitude, longitude: clip.longitude, week: clip.week)

        let events = try await collect(engine.identify(WAVFileAudioSource(url: clip.url), in: context))

        let stack = events.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }.last ?? CandidateStack()
        let windows = events.compactMap { if case .window(let report) = $0 { report } else { nil } }
        print("\(clip.file): \(windows.count) windows, slowest inference \(windows.map(\.inference).max() ?? .zero); stack \(stack.ranked.map { "\($0.species.commonName) \($0.score)" })")

        let topThree = stack.ranked.prefix(3).map(\.species.scientificName)
        for expected in clip.expected {
            #expect(topThree.contains(expected), "\(expected) not in top three \(topThree) for \(clip.file)")
            if let budget = clip.withinSeconds, let candidate = stack.candidates.first(where: { $0.species.scientificName == expected }) {
                #expect(candidate.admittedAt <= budget, "\(expected) admitted at \(candidate.admittedAt) s, after the \(budget) s budget, for \(clip.file)")
            }
        }
        let admitted = Set(stack.candidates.map(\.species.scientificName))
        for absent in clip.absent {
            #expect(!admitted.contains(absent), "\(absent) appeared for \(clip.file)")
        }
        // Every admitted species passed the prior at the threshold, and the filter removed something the model heard.
        let occurrence = try geo.occurrence(in: context)
        #expect(stack.candidates.allSatisfy { occurrence[$0.species.scientificName]! >= 0.03 && $0.species.taxonomicClass == Species.birds })
        var unfiltered = IdentificationConfiguration()
        unfiltered.occurrenceThreshold = 0
        unfiltered.taxonomicClasses = nil
        let everywhere = IdentificationEngine(model: model, occurrenceModel: FixedOccurrence(Dictionary(uniqueKeysWithValues: model.species.map { ($0.scientificName, Float(1)) })), configuration: unfiltered)
        let unfilteredEvents = try await collect(everywhere.identify(WAVFileAudioSource(url: clip.url), in: context))
        let unfilteredStack = unfilteredEvents.compactMap { if case .stack(let stack) = $0 { stack } else { nil } }.last ?? CandidateStack()
        let heardEverywhere = Set(unfilteredStack.candidates.map(\.species.scientificName))
        print("\(clip.file): unfiltered stack \(unfilteredStack.ranked.map { "\($0.species.commonName) \($0.score)" })")
        #expect(admitted.isSubset(of: heardEverywhere))
        #expect(heardEverywhere.subtracting(admitted).isEmpty == false, "the geomodel filter removed nothing from \(clip.file)")
    }

    private func collect(_ stream: AsyncThrowingStream<IdentificationEvent, any Error>) async throws -> [IdentificationEvent] {
        var events: [IdentificationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

// MARK: - Test doubles

import Synchronization

/// Three-species model that returns pre-scripted scores per window and records what it was fed.
final class ScriptedBirdModel: BirdModel {
    let species = [
        Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves"),
        Species(index: 1, scientificName: "Cyanocitta cristata", commonName: "Blue Jay", taxonomicClass: "Aves"),
        Species(index: 2, scientificName: "Turdus migratorius", commonName: "American Robin", taxonomicClass: "Aves"),
    ]
    let sampleRate = 32_000
    let scoresPerWindow: [[Float]]
    let windowSampleCounts = Mutex<[Int]>([])

    init(scoresPerWindow: [[Float]]) {
        self.scoresPerWindow = scoresPerWindow
    }

    func scores(for samples: [Float]) throws -> [Float] {
        let index = windowSampleCounts.withLock { counts in
            counts.append(samples.count)
            return counts.count - 1
        }
        return index < scoresPerWindow.count ? scoresPerWindow[index] : [0, 0, 0]
    }
}

/// One-species model whose score is the fraction of loud samples in the window.
struct LoudnessBirdModel: BirdModel {
    let species = [Species(index: 0, scientificName: "Haemorhous mexicanus", commonName: "House Finch", taxonomicClass: "Aves")]
    let sampleRate = 32_000
    func scores(for samples: [Float]) throws -> [Float] {
        [Float(samples.filter { abs($0) > 0.1 }.count) / Float(samples.count)]
    }
}

struct FailingBirdModel: BirdModel {
    struct Failure: Error {}
    let species = [Species(index: 0, scientificName: "X x", commonName: "X", taxonomicClass: "Aves")]
    let sampleRate = 32_000
    func scores(for samples: [Float]) throws -> [Float] { throw Failure() }
}

/// A prior that must not be asked: no location means no geo filter.
struct ThrowingOccurrence: SpeciesOccurrenceModel {
    struct Asked: Error {}
    func occurrence(in context: GeoContext) throws -> [String: Float] { throw Asked() }
}

/// A prior whose answer depends on where the session is, recording every latitude it was asked about.
final class OccurrenceByLatitude: SpeciesOccurrenceModel {
    let tables: [Int: [String: Float]]
    let asked = Mutex<[Double]>([])
    init(_ tables: [Int: [String: Float]]) { self.tables = tables }
    func occurrence(in context: GeoContext) throws -> [String: Float] {
        asked.withLock { $0.append(context.latitude) }
        return tables[Int(context.latitude.rounded(.down))] ?? [:]
    }
}

/// Silence fed by the test, one chunk per `feed`, at the model rate so windows fall exactly where expected.
final class ManualAudioSource: AudioSource {
    let sampleRate = 32_000
    private let stream: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let fed = Mutex<Double>(0)

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
    }

    func start() async throws -> AsyncStream<AudioChunk> { stream }
    func stop() async { continuation.finish() }

    func feed(seconds: Double, amplitude: Float = 0) {
        let start = fed.withLock { start in
            defer { start += seconds }
            return start
        }
        let samples = [Float](repeating: amplitude, count: Int(seconds * Double(sampleRate)))
        continuation.yield(AudioChunk(samples: samples, sampleRate: sampleRate, presentationTime: start))
    }
}

struct FixedOccurrence: SpeciesOccurrenceModel {
    let table: [String: Float]
    init(_ table: [String: Float]) { self.table = table }
    func occurrence(in context: GeoContext) throws -> [String: Float] { table }
}

// MARK: - External clips (fixtures/clips.json)

/// One labeled recording kept outside the repo: see fixtures/README.md.
struct ExternalClip: Decodable, CustomTestStringConvertible {
    var file: String
    var latitude: Double
    var longitude: Double
    var week: Int
    var expected: [String]
    var absent: [String] = []
    /// Seconds into the clip by which each expected species must have been admitted, if given.
    var withinSeconds: Double?
    var url: URL { ExternalClips.fixturesDirectory.appending(path: file) }
    var testDescription: String { file }

    private enum CodingKeys: String, CodingKey { case file, latitude, longitude, week, expected, absent, withinSeconds }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        week = try container.decode(Int.self, forKey: .week)
        expected = try container.decode([String].self, forKey: .expected)
        absent = try container.decodeIfPresent([String].self, forKey: .absent) ?? []
        withinSeconds = try container.decodeIfPresent(Double.self, forKey: .withinSeconds)
    }
}

enum ExternalClips {
    /// The repo's fixtures/ directory, reachable from the simulator through the host file system. On a device
    /// there is no checkout, so no clips run.
    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "fixtures")

    /// Clips whose files are present on this machine.
    static func available() -> [ExternalClip] {
        struct Manifest: Decodable { var clips: [ExternalClip] }
        guard let data = try? Data(contentsOf: fixturesDirectory.appending(path: "clips.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.clips.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
}
