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
