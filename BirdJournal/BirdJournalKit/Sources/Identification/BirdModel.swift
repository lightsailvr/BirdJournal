import Foundation
import Synchronization

/// The acoustic model seam. BirdNET+ V3.0 is the shipped implementation; a v2.4 port would conform the same way.
public protocol BirdModel: Sendable {
    /// Output classes in output order.
    var species: [Species] { get }
    /// Sample rate the model expects.
    var sampleRate: Int { get }
    /// One score in [0, 1] per class for a window of mono samples at `sampleRate`. Synchronous and CPU-bound;
    /// callers run it off the main thread.
    func scores(for samples: [Float]) throws -> [Float]
}

/// Where and when the session listens. `week` uses BirdNET's 48-week year: four weeks per month.
public struct GeoContext: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let week: Int

    public init(latitude: Double, longitude: Double, week: Int) {
        precondition((1...48).contains(week), "week must be in 1...48")
        self.latitude = latitude
        self.longitude = longitude
        self.week = week
    }

    public init(latitude: Double, longitude: Double, date: Date, calendar: Calendar = .current) {
        self.init(latitude: latitude, longitude: longitude, week: Self.week(of: date, calendar: calendar))
    }

    /// BirdNET's week number: days 1–7 of a month are week 1 of that month, 8–14 week 2, 15–21 week 3, 22–31 week 4.
    public static func week(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return (parts.month! - 1) * 4 + min(4, (parts.day! + 6) / 7)
    }
}

/// Where and when a running session listens, changeable while it runs: the phone takes one fix at start and
/// refreshes it every ten minutes (DECISIONS.md, "Audio and identification"). Nil means no location: the geo prior
/// is skipped and only the class restriction applies. An update takes effect from the next analysis window.
public final class LiveGeoContext: Sendable {
    private struct State {
        var context: GeoContext?
        var version = 0
    }

    private let state: Mutex<State>

    public init(_ context: GeoContext?) {
        state = Mutex(State(context: context))
    }

    public var context: GeoContext? { state.withLock { $0.context } }

    public func update(_ context: GeoContext?) {
        state.withLock {
            $0.context = context
            $0.version += 1
        }
    }

    /// The current context with a counter that changes on every update, so a reader can tell "same place again"
    /// from "moved".
    func snapshot() -> (version: Int, context: GeoContext?) {
        state.withLock { ($0.version, $0.context) }
    }
}

/// The geo prior seam: how likely each species is at a place and week.
public protocol SpeciesOccurrenceModel: Sendable {
    /// Occurrence probability in [0, 1] keyed by scientific name. Species the model does not know are absent.
    func occurrence(in context: GeoContext) throws -> [String: Float]
}

/// Decides which acoustic classes a session may admit: those the geo prior puts at or above `threshold`
/// (DECISIONS.md: 0.03), restricted to `taxonomicClasses` when given. A class the prior does not know is excluded.
/// With no prior (`occurrence` nil: the session has no location), only the class restriction applies.
public enum SpeciesFilter {
    public static func allowed(species: [Species], occurrence: [String: Float]?, threshold: Float, taxonomicClasses: Set<String>?) -> [Bool] {
        species.map { candidate in
            if let classes = taxonomicClasses, !classes.contains(candidate.taxonomicClass) { return false }
            guard let occurrence else { return true }
            guard let probability = occurrence[candidate.scientificName] else { return false }
            return probability >= threshold
        }
    }
}

