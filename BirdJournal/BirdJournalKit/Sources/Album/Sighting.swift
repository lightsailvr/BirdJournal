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
/// column is a lightweight migration; every earlier sighting and its frame survive it untouched. Kept so the
/// migration plan can name it.
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

/// The album since every sighting became a card (issue #51): a sighting also carries a stable identifier, the method
/// (Heard unless the birder says otherwise), the rarity snapshot taken at the add, the caption, the art state and the
/// original photos the birder attached beside the glasses photo. Every field the collection needs arrives in this one
/// version, so later work fills them in without another migration. A card is not stored apart: it is the sighting.
public enum AlbumSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self] }

    @Model
    public final class Sighting {
        /// Stable across launches, backups and edits; what art jobs, finds and the collection's tie-break refer to.
        /// A sighting migrated from schema 2 gets a fresh one in the migration stage.
        public var identifier: UUID = UUID()
        /// BirdNET label, e.g. "Sayornis nigricans_Black Phoebe". Names and photos come from the species pack.
        public var speciesID: String
        public var confirmedAt: Date
        public var location: Coordinate?
        public var soundConfidence: Double
        /// The glasses photo from the add (or the stream frame standing in for it), relative to the `FrameStore`.
        public var frameImagePath: String?
        public var source: SightingSource
        /// What the birder wrote about this sighting on the phone, nil until they do.
        public var note: String?
        public var method: SightingMethod = SightingMethod.heard
        /// How unusual the bird was at the add's place and week, saved once and never recomputed; nil without a
        /// location.
        public var rarity: RaritySnapshot?
        public var caption: CardCaption?
        /// The card art's state as JSON, so the art pipeline can grow without another schema version; read through
        /// `art`.
        public var artState: Data?
        /// Original photos the birder attached, relative to the `FrameStore`, oldest first. Evidence, never art.
        public var attachedPhotoPaths: [String] = []

        public init(
            identifier: UUID = UUID(),
            speciesID: String,
            confirmedAt: Date,
            location: Coordinate? = nil,
            soundConfidence: Double,
            frameImagePath: String? = nil,
            source: SightingSource,
            note: String? = nil,
            method: SightingMethod = .heard
        ) {
            self.identifier = identifier
            self.speciesID = speciesID
            self.confirmedAt = confirmedAt
            self.location = location
            self.soundConfidence = soundConfidence
            self.frameImagePath = frameImagePath
            self.source = source
            self.note = note
            self.method = method
        }

        /// The card's art: what has been painted or attached, and the art job under way. Empty until the art
        /// pipeline writes it; the card shows pack art (or the reference photo) meanwhile.
        public var art: CardArt {
            get { artState.flatMap { try? JSONDecoder().decode(CardArt.self, from: $0) } ?? CardArt() }
            set { artState = newValue == CardArt() ? nil : try? JSONEncoder().encode(newValue) }
        }
    }
}

public typealias Sighting = AlbumSchemaV3.Sighting

/// How the birder met the bird on a sighting. Every add is Heard; the birder changes it on the phone.
public enum SightingMethod: String, Codable, Sendable, CaseIterable {
    case heard
    case seen

    /// "Heard" or "Seen".
    public var title: String {
        switch self {
        case .heard: "Heard"
        case .seen: "Seen"
        }
    }
}

/// How unusual a species is at a place and week (ADR-0006), as a card shows it.
public enum RarityLabel: String, Codable, Sendable, CaseIterable {
    case common
    case uncommon
    case rare
    case exceptional
}

/// The rarity taken at the add (issue #52, ADR-0006): the geomodel's occurrence probability, the label it mapped to
/// under `calibrationVersion`, and the week of BirdNET's 48-week year it was read for. A sighting without a location
/// or of a species the geomodel doesn't know has no snapshot at all. `occurrence` is optional only in the schema;
/// every reading saves it.
public struct RaritySnapshot: Codable, Sendable, Equatable {
    public var occurrence: Double?
    public var label: RarityLabel
    public var calibrationVersion: Int
    public var week: Int

    public init(occurrence: Double?, label: RarityLabel, calibrationVersion: Int, week: Int) {
        self.occurrence = occurrence
        self.label = label
        self.calibrationVersion = calibrationVersion
        self.week = week
    }
}

/// A card's one-line caption, written on the phone for that sighting, with the generator that wrote it.
public struct CardCaption: Codable, Sendable, Equatable {
    public var text: String
    public var generatorVersion: String

    public init(text: String, generatorVersion: String) {
        self.text = text
        self.generatorVersion = generatorVersion
    }
}

/// A card's art beyond the pack's: the scene and photo art with their states, whether the birder chose pack art over
/// scene art, and the art job under way.
public struct CardArt: Codable, Sendable, Equatable {
    /// "Use pack art": scene art stays on file but the card shows the pack's.
    public var prefersPackArt: Bool
    public var scene: ArtImage?
    public var photo: ArtImage?
    public var job: ArtJob?

    public init(prefersPackArt: Bool = false, scene: ArtImage? = nil, photo: ArtImage? = nil, job: ArtJob? = nil) {
        self.prefersPackArt = prefersPackArt
        self.scene = scene
        self.photo = photo
        self.job = job
    }
}

/// One painted image of a card, relative to the `FrameStore` once it is on the phone.
public struct ArtImage: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Painted, waiting for the birder's approval (photo art only).
        case preview
        case ready
        case failed
    }

    public var path: String?
    public var state: State

    public init(path: String?, state: State) {
        self.path = path
        self.state = state
    }
}

/// One request to paint art for a card. A retry is a new job for the same sighting.
public struct ArtJob: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case scene
        case photo
    }

    public enum State: String, Codable, Sendable {
        case queued
        case painting
        case ready
        case failed
    }

    public var id: UUID
    public var kind: Kind
    public var state: State
    public var attempts: Int

    public init(id: UUID, kind: Kind, state: State, attempts: Int) {
        self.id = id
        self.kind = kind
        self.state = state
        self.attempts = attempts
    }
}

/// How the album moves between schema versions: a lightweight stage to schema 2; to schema 3 a custom stage that gives
/// every sighting its own identifier and the method Heard (a column default would give them all the same identifier).
public enum AlbumMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AlbumSchemaV1.self, AlbumSchemaV2.self, AlbumSchemaV3.self] }
    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: AlbumSchemaV1.self, toVersion: AlbumSchemaV2.self),
            .custom(fromVersion: AlbumSchemaV2.self, toVersion: AlbumSchemaV3.self, willMigrate: nil, didMigrate: { context in
                for sighting in try context.fetch(FetchDescriptor<AlbumSchemaV3.Sighting>()) {
                    sighting.identifier = UUID()
                    sighting.method = .heard
                }
                try context.save()
            }),
        ]
    }
}

/// The album's persistent schema and container factory.
public enum AlbumSchema {
    public static let models: [any PersistentModel.Type] = AlbumSchemaV3.models

    /// The app's album: on disk in the default store, migrated through `AlbumMigrationPlan`; or in memory.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// An album at `url`, for tests that open the same file under different schema versions.
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(url: url))
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV3.self), migrationPlan: AlbumMigrationPlan.self, configurations: [configuration])
    }
}

extension Sighting {
    /// The album's order (issue #11): newest first.
    public static func newestFirst() -> FetchDescriptor<Sighting> {
        FetchDescriptor<Sighting>(sortBy: [SortDescriptor(\.confirmedAt, order: .reverse)])
    }

    /// The scientific name half of the BirdNET label; the whole label when it has no underscore.
    public var scientificName: String { String(speciesID.prefix { $0 != "_" }) }

    /// Every file on disk the sighting refers to, relative to the `FrameStore`: the glasses photo, the attached
    /// originals and the painted art. What goes when the sighting does.
    public var filePaths: [String] {
        [frameImagePath].compactMap { $0 } + attachedPhotoPaths + [art.scene?.path, art.photo?.path].compactMap { $0 }
    }

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
