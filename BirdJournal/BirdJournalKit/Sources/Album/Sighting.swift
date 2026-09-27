import Foundation
import SwiftData

/// Where a sighting was confirmed from.
public enum SightingSource: String, Codable, Sendable {
    case glasses
    case phone
}

/// A location fix with its horizontal accuracy in metres.
public struct Coordinate: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double

    public init(latitude: Double, longitude: Double, accuracy: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }
}

/// A confirmed, saved identification (spec "Album store"). No audio is stored; the most recent camera frame
/// is written to disk and referenced by path.
@Model
public final class Sighting {
    /// BirdNET label, e.g. "Sayornis nigricans_Black Phoebe". Names and photos come from the species pack.
    public var speciesID: String
    public var confirmedAt: Date
    public var location: Coordinate?
    public var soundConfidence: Double
    public var frameImagePath: String?
    public var source: SightingSource

    public init(
        speciesID: String,
        confirmedAt: Date,
        location: Coordinate? = nil,
        soundConfidence: Double,
        frameImagePath: String? = nil,
        source: SightingSource
    ) {
        self.speciesID = speciesID
        self.confirmedAt = confirmedAt
        self.location = location
        self.soundConfidence = soundConfidence
        self.frameImagePath = frameImagePath
        self.source = source
    }
}

/// The album's persistent schema and container factory.
public enum AlbumSchema {
    public static let models: [any PersistentModel.Type] = [Sighting.self]

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: [configuration])
    }
}

extension Sighting {
    /// The album's order (issue #11): newest first.
    public static func newestFirst() -> FetchDescriptor<Sighting> {
        FetchDescriptor<Sighting>(sortBy: [SortDescriptor(\.confirmedAt, order: .reverse)])
    }

    /// The scientific name half of the BirdNET label; the whole label when it has no underscore.
    public var scientificName: String { String(speciesID.prefix { $0 != "_" }) }

    /// The common name half of the BirdNET label, so a species the pack lacks still has a name (spec user story 40).
    public var commonName: String {
        guard let underscore = speciesID.firstIndex(of: "_") else { return speciesID }
        return String(speciesID[speciesID.index(after: underscore)...])
    }
}

extension Coordinate {
    /// Degrees with hemispheres to two decimals, e.g. "34.05° N, 118.24° W": the place line when there is no
    /// place name.
    public var formatted: String { formatted(locale: .current) }

    public func formatted(locale: Locale) -> String {
        let degrees = FloatingPointFormatStyle<Double>.number.locale(locale).precision(.fractionLength(2))
        let lat = "\(abs(latitude).formatted(degrees))° \(latitude < 0 ? "S" : "N")"
        let lon = "\(abs(longitude).formatted(degrees))° \(longitude < 0 ? "W" : "E")"
        return "\(lat), \(lon)"
    }
}
