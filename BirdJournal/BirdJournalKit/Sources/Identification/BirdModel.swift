import Foundation

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

/// The geo prior seam: how likely each species is at a place and week.
public protocol SpeciesOccurrenceModel: Sendable {
    /// Occurrence probability in [0, 1] keyed by scientific name. Species the model does not know are absent.
    func occurrence(in context: GeoContext) throws -> [String: Float]
}

/// Decides which acoustic classes a session may admit: those the geo prior puts at or above `threshold`
/// (DECISIONS.md: 0.03), restricted to `taxonomicClasses` when given. A class the prior does not know is excluded.
public enum SpeciesFilter {
    public static func allowed(species: [Species], occurrence: [String: Float], threshold: Float, taxonomicClasses: Set<String>?) -> [Bool] {
        species.map { candidate in
            if let classes = taxonomicClasses, !classes.contains(candidate.taxonomicClass) { return false }
            guard let probability = occurrence[candidate.scientificName] else { return false }
            return probability >= threshold
        }
    }
}

