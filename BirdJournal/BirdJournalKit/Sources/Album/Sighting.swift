import Foundation
import SwiftData

/// A confirmed, saved identification. No audio is stored; the most recent camera frame may be.
@Model
public final class Sighting {
    /// BirdNET label, e.g. "Sayornis nigricans_Black Phoebe".
    public var speciesLabel: String
    public var commonName: String
    public var confidence: Double
    public var heardAt: Date
    public var latitude: Double?
    public var longitude: Double?
    @Attribute(.externalStorage) public var photo: Data?

    public init(
        speciesLabel: String,
        commonName: String,
        confidence: Double,
        heardAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        photo: Data? = nil
    ) {
        self.speciesLabel = speciesLabel
        self.commonName = commonName
        self.confidence = confidence
        self.heardAt = heardAt
        self.latitude = latitude
        self.longitude = longitude
        self.photo = photo
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
