import Foundation
import os

/// Tunables for one engine. Defaults follow DECISIONS.md and issue #5; thresholds are tuned in phase B.
public struct IdentificationConfiguration: Sendable, Equatable {
    /// Per-window score a species needs for the window to count toward admission. BirdNET's reference tools
    /// default to 0.15.
    public var windowThreshold: Float = 0.15
    /// Windows at or above `windowThreshold` before a species enters the stack.
    public var admissionWindows = 2
    /// Geomodel occurrence needed for a species to be admissible at all.
    public var occurrenceThreshold: Float = 0.03
    /// Taxonomic classes that may be admitted; nil admits every class the geomodel allows. Birds only by default:
    /// the acoustic model also knows dogs, humans and insects, which a bird journal should not list.
    public var taxonomicClasses: Set<String>? = [Species.birds]
    public var windowDuration: Double = 3
    public var hopDuration: Double = 1.5
    /// Inference time per window above which a warning is logged (issue #5: 150 ms on an iPhone 17 Pro).
    public var inferenceBudget: Duration = .milliseconds(150)

    public init() {}
}

/// What one analysis window produced. Inference time is what the model call took, excluding resampling.
public struct WindowReport: Sendable, Equatable {
    /// Seconds into the session at which the window starts.
    public let start: Double
    public let inference: Duration
    public let topScore: Float
    public let topSpecies: Species?
}

public enum IdentificationEvent: Sendable, Equatable {
    case window(WindowReport)
    /// The stack after a window changed it. Sent only when something changed.
    case stack(CandidateStack)
}

/// Turns a session's audio into a `CandidateStack`: resample to the model rate, cut 3 s windows every 1.5 s, score
/// each with the acoustic model, keep the species the geo prior allows and admit them after two windows above
/// threshold (spec, "Identification engine"). One engine can run many sessions, one at a time each.
public final class IdentificationEngine: Sendable {
    public let model: any BirdModel
    public let occurrenceModel: any SpeciesOccurrenceModel
    public let configuration: IdentificationConfiguration

    private static let logger = Logger(subsystem: "com.matthewcelia.mybirdjournal", category: "identification")

    public init(model: any BirdModel, occurrenceModel: any SpeciesOccurrenceModel, configuration: IdentificationConfiguration = IdentificationConfiguration()) {
        self.model = model
        self.occurrenceModel = occurrenceModel
        self.configuration = configuration
    }

    /// Classes admissible in `context`, one flag per model class.
    public func allowedSpecies(in context: GeoContext) throws -> [Bool] {
        SpeciesFilter.allowed(
            species: model.species,
            occurrence: try occurrenceModel.occurrence(in: context),
            threshold: configuration.occurrenceThreshold,
            taxonomicClasses: configuration.taxonomicClasses
        )
    }

    /// Starts `source` and identifies until it ends or the consumer cancels. Errors from the prior or the source
    /// surface here; a failing model call ends the stream with its error.
    public func identify(_ source: any AudioSource, in context: GeoContext) async throws -> AsyncThrowingStream<IdentificationEvent, any Error> {
        let allowed = try allowedSpecies(in: context)
        let chunks = try await source.start()
        let (events, continuation) = AsyncThrowingStream.makeStream(of: IdentificationEvent.self)
        let worker = Task.detached(priority: .userInitiated) { [model, configuration] in
            var aggregator = CandidateAggregator(
                species: model.species,
                allowed: allowed,
                windowThreshold: configuration.windowThreshold,
                admissionWindows: configuration.admissionWindows
            )
            let planner = WindowPlanner(sampleRate: model.sampleRate, windowDuration: configuration.windowDuration, hopDuration: configuration.hopDuration)
            var windower = StreamingWindower(planner: planner)
            let resampler = AudioResampler(outputRate: model.sampleRate)
            let clock = ContinuousClock()

            func process(_ samples: [Float]) throws {
                for window in windower.append(samples) {
                    let start = Double(window.start) / Double(model.sampleRate)
                    let began = clock.now
                    let scores = try model.scores(for: window.samples)
                    let inference = clock.now - began
                    let top = scores.indices.max { scores[$0] < scores[$1] }
                    let report = WindowReport(start: start, inference: inference, topScore: top.map { scores[$0] } ?? 0, topSpecies: top.map { model.species[$0] })
                    Self.log(report, configuration: configuration)
                    continuation.yield(.window(report))
                    if aggregator.observe(scores, at: start) {
                        continuation.yield(.stack(aggregator.stack))
                    }
                }
            }

            do {
                for await chunk in chunks {
                    try Task.checkCancellation()
                    try process(try resampler.resample(chunk))
                }
                try process(try resampler.flush())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await source.stop()
        }
        continuation.onTermination = { _ in worker.cancel() }
        return events
    }

    private static func log(_ report: WindowReport, configuration: IdentificationConfiguration) {
        let milliseconds = Double(report.inference.components.attoseconds) / 1e15 + Double(report.inference.components.seconds) * 1_000
        let top = report.topSpecies?.commonName ?? "none"
        if report.inference > configuration.inferenceBudget {
            logger.warning("window \(report.start, format: .fixed(precision: 1), privacy: .public) s: inference \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms over budget; top \(top, privacy: .public) \(report.topScore, format: .fixed(precision: 3), privacy: .public)")
        } else {
            logger.info("window \(report.start, format: .fixed(precision: 1), privacy: .public) s: inference \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms; top \(top, privacy: .public) \(report.topScore, format: .fixed(precision: 3), privacy: .public)")
        }
    }
}
