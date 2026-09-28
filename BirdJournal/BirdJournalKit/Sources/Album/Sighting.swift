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

/// The album as it was first shipped (issues #9 and #11): a sighting is a species, a time, a place, a match score,
/// a source and an optional camera frame. Kept so the migration plan can name it.
public enum AlbumSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self] }

    @Model
    public final class Sighting {
        public var speciesID: String
        public var confirmedAt: Date
        public var location: Coordinate?
        public var soundConfidence: Double
        public var frameImagePath: String?
        public var source: SightingSource

        public init(speciesID: String, confirmedAt: Date, location: Coordinate? = nil, soundConfidence: Double, frameImagePath: String? = nil, source: SightingSource) {
            self.speciesID = speciesID
            self.confirmedAt = confirmedAt
            self.location = location
            self.soundConfidence = soundConfidence
            self.frameImagePath = frameImagePath
            self.source = source
        }
    }
}

/// The album since the field journal (issue #28): a sighting also carries the birder's own note. Adding an optional
/// column is a lightweight migration; every earlier sighting and its frame survive it untouched.
public enum AlbumSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self] }

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
        /// What the birder wrote about this sighting on the phone, nil until they do.
        public var note: String?

        public init(
            speciesID: String,
            confirmedAt: Date,
            location: Coordinate? = nil,
            soundConfidence: Double,
            frameImagePath: String? = nil,
            source: SightingSource,
            note: String? = nil
        ) {
            self.speciesID = speciesID
            self.confirmedAt = confirmedAt
            self.location = location
            self.soundConfidence = soundConfidence
            self.frameImagePath = frameImagePath
            self.source = source
            self.note = note
        }
    }
}

public typealias Sighting = AlbumSchemaV2.Sighting

/// How the album moves between schema versions: one lightweight stage per version so far.
public enum AlbumMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AlbumSchemaV1.self, AlbumSchemaV2.self] }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: AlbumSchemaV1.self, toVersion: AlbumSchemaV2.self)]
    }
}

/// The album's persistent schema and container factory.
public enum AlbumSchema {
    public static let models: [any PersistentModel.Type] = AlbumSchemaV2.models

    /// The app's album: on disk in the default store, migrated through `AlbumMigrationPlan`; or in memory.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// An album at `url`, for tests that open the same file under different schema versions.
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(url: url))
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV2.self), migrationPlan: AlbumMigrationPlan.self, configurations: [configuration])
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
