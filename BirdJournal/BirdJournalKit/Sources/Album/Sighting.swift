import Foundation
import SwiftData

/// Where a sighting was confirmed from.
public enum SightingSource: String, Codable, Sendable {
    case glasses
    case phone
}

/// A location fix with its horizontal accuracy in metres.
public struct Coordinate: Codable, Sendable, Hashable {
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
/// The album as shipped up to #185. Kept so the migration plan can name it.
public enum AlbumSchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self] }

    @Model
    public final class Sighting {
        /// Stable across launches, backups and edits; what finds and the collection's tie-break refer to.
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
        /// Scene and photo art as JSON (issues #68 to #70, retired by #137). Nothing writes it for a new sighting, but
        /// stored sightings keep what they have: read through `art`, and no schema version was needed to retire it.
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

        /// What a stored sighting's art state says: the only use left is its files, which go with it (`filePaths`).
        /// Art that can't be read is treated as none, so a sighting always opens.
        public var art: CardArt {
            get { artState.flatMap { try? JSONDecoder().decode(CardArt.self, from: $0) } ?? CardArt() }
            set { artState = newValue == CardArt() ? nil : try? JSONEncoder().encode(newValue) }
        }
    }
}

/// The album since a seen bird could be captured and named (issue #186, of #185): a sighting also says whether the birder
/// named the bird themselves. Every stored sighting was heard by BirdNET, so adding the column with its default is a
/// lightweight migration. Kept so the migration plan can name it.
public enum AlbumSchemaV4: VersionedSchema {
    public static let versionIdentifier = Schema.Version(4, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self] }

    @Model
    public final class Sighting {
        /// Stable across launches, backups and edits; what finds and the collection's tie-break refer to.
        /// A sighting migrated from schema 2 gets a fresh one in the migration stage.
        public var identifier: UUID = UUID()
        /// BirdNET label, e.g. "Sayornis nigricans_Black Phoebe". Names and photos come from the species pack.
        public var speciesID: String
        public var confirmedAt: Date
        public var location: Coordinate?
        /// BirdNET's match score at the add. Meaningless, 0 and never shown, on a sighting `namedByBirder`.
        public var soundConfidence: Double
        /// The glasses photo from the add (or the stream frame standing in for it), relative to the `FrameStore`.
        public var frameImagePath: String?
        /// The device the sighting came from: the one that heard the bird, or took the photo of one the birder named.
        public var source: SightingSource
        /// What the birder wrote about this sighting on the phone, nil until they do.
        public var note: String?
        public var method: SightingMethod = SightingMethod.heard
        /// How unusual the bird was at the add's place and week, saved once and never recomputed; nil without a
        /// location.
        public var rarity: RaritySnapshot?
        public var caption: CardCaption?
        /// Scene and photo art as JSON (issues #68 to #70, retired by #137). Nothing writes it for a new sighting, but
        /// stored sightings keep what they have: read through `art`, and no schema version was needed to retire it.
        public var artState: Data?
        /// Original photos of the birder's own, relative to the `FrameStore`, oldest first: one attached from the library,
        /// or the capture a seen bird was named from (issue #186). Evidence, never art.
        public var attachedPhotoPaths: [String] = []
        /// The birder named the bird themselves, from a photo of it (issue #186): BirdNET matched nothing, so there is no
        /// match score to show and nothing to explain about one. False for every add of a candidate.
        public var namedByBirder: Bool = false

        public init(
            identifier: UUID = UUID(),
            speciesID: String,
            confirmedAt: Date,
            location: Coordinate? = nil,
            soundConfidence: Double,
            frameImagePath: String? = nil,
            source: SightingSource,
            note: String? = nil,
            method: SightingMethod = .heard,
            namedByBirder: Bool = false
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
            self.namedByBirder = namedByBirder
        }

        /// What a stored sighting's art state says: the only use left is its files, which go with it (`filePaths`).
        /// Art that can't be read is treated as none, so a sighting always opens.
        public var art: CardArt {
            get { artState.flatMap { try? JSONDecoder().decode(CardArt.self, from: $0) } ?? CardArt() }
            set { artState = newValue == CardArt() ? nil : try? JSONEncoder().encode(newValue) }
        }
    }
}

/// The album since a photo could wait for its name (issue #188, of #185): beside the sightings it holds captures, photos of
/// birds not yet named. A sighting is as schema 4 has it; the capture is a new model, so the stage from schema 4 is
/// lightweight and every sighting stays as it was.
public enum AlbumSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)
    public static var models: [any PersistentModel.Type] { [Sighting.self, Capture.self] }

    @Model
    public final class Sighting {
        /// Stable across launches, backups and edits; what finds and the collection's tie-break refer to.
        /// A sighting migrated from schema 2 gets a fresh one in the migration stage.
        public var identifier: UUID = UUID()
        /// BirdNET label, e.g. "Sayornis nigricans_Black Phoebe". Names and photos come from the species pack.
        public var speciesID: String
        public var confirmedAt: Date
        public var location: Coordinate?
        /// BirdNET's match score at the add. Meaningless, 0 and never shown, on a sighting `namedByBirder`.
        public var soundConfidence: Double
        /// The glasses photo from the add (or the stream frame standing in for it), relative to the `FrameStore`.
        public var frameImagePath: String?
        /// The device the sighting came from: the one that heard the bird, or took the photo of one the birder named.
        public var source: SightingSource
        /// What the birder wrote about this sighting on the phone, nil until they do.
        public var note: String?
        public var method: SightingMethod = SightingMethod.heard
        /// How unusual the bird was at the add's place and week, saved once and never recomputed; nil without a
        /// location.
        public var rarity: RaritySnapshot?
        public var caption: CardCaption?
        /// Scene and photo art as JSON (issues #68 to #70, retired by #137). Nothing writes it for a new sighting, but
        /// stored sightings keep what they have: read through `art`, and no schema version was needed to retire it.
        public var artState: Data?
        /// Original photos of the birder's own, relative to the `FrameStore`, oldest first: one attached from the library,
        /// or the capture a seen bird was named from (issue #186). Evidence, never art.
        public var attachedPhotoPaths: [String] = []
        /// The birder named the bird themselves, from a photo of it (issue #186): BirdNET matched nothing, so there is no
        /// match score to show and nothing to explain about one. False for every add of a candidate.
        public var namedByBirder: Bool = false

        public init(
            identifier: UUID = UUID(),
            speciesID: String,
            confirmedAt: Date,
            location: Coordinate? = nil,
            soundConfidence: Double,
            frameImagePath: String? = nil,
            source: SightingSource,
            note: String? = nil,
            method: SightingMethod = .heard,
            namedByBirder: Bool = false
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
            self.namedByBirder = namedByBirder
        }

        /// What a stored sighting's art state says: the only use left is its files, which go with it (`filePaths`).
        /// Art that can't be read is treated as none, so a sighting always opens.
        public var art: CardArt {
            get { artState.flatMap { try? JSONDecoder().decode(CardArt.self, from: $0) } ?? CardArt() }
            set { artState = newValue == CardArt() ? nil : try? JSONEncoder().encode(newValue) }
        }
    }

    /// A capture (issue #188): a photo of a bird with its time, place and source, not yet a sighting. It is written the
    /// moment the photo is taken and waits, for as long as it takes, to be named; naming it writes a sighting with its time,
    /// place, source and photo, and the capture goes. Until then it is no part of the collection: it sews no patch, counts
    /// toward no set and is published nowhere, which holds because nothing that reads sightings ever sees one. In copy, an
    /// unnamed sighting.
    @Model
    public final class Capture {
        /// Stable across launches; what a run remembers its captures by.
        public var identifier: UUID = UUID()
        /// When the photo was taken: the time of the sighting it becomes.
        public var takenAt: Date
        /// Where the birder was when the photo was taken; nil when no place was known.
        public var location: Coordinate?
        /// The photo as the camera wrote it, relative to the `FrameStore`. It becomes the sighting's original photo.
        public var photoPath: String
        /// The device that took the photo.
        public var source: SightingSource

        public init(identifier: UUID = UUID(), takenAt: Date, location: Coordinate? = nil, photoPath: String, source: SightingSource) {
            self.identifier = identifier
            self.takenAt = takenAt
            self.location = location
            self.photoPath = photoPath
            self.source = source
        }
    }
}

public typealias Sighting = AlbumSchemaV5.Sighting
public typealias Capture = AlbumSchemaV5.Capture

/// How the birder met the bird on a sighting. An add of a candidate is Heard unless the birder says otherwise, there or
/// later on the phone; a bird they named from a photo is Seen.
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

/// A stored sighting's scene and photo art with their states, as issues #68 to #70 wrote them. Retired by #137: nothing shows
/// or changes it. Kept only to read what is stored, so these types say what the JSON holds and nothing more.
public struct CardArt: Codable, Sendable, Equatable {
    /// "Use pack art": scene art stays on file but the card shows the pack's.
    public var prefersPackArt: Bool
    public var scene: ArtImage?
    /// Approved photo art: what the card shows above everything else.
    public var photo: ArtImage?
    /// Photo art painted and waiting for the birder: Approve, Keep original or Try again. Any approved photo art stays
    /// on the card meanwhile.
    public var photoPreview: ArtImage?
    /// The scene job (issue #68).
    public var job: ArtJob?
    /// The photo-art job (issue #69).
    public var photoJob: ArtJob?

    public init(
        prefersPackArt: Bool = false, scene: ArtImage? = nil, photo: ArtImage? = nil, photoPreview: ArtImage? = nil, job: ArtJob? = nil,
        photoJob: ArtJob? = nil
    ) {
        self.prefersPackArt = prefersPackArt
        self.scene = scene
        self.photo = photo
        self.photoPreview = photoPreview
        self.job = job
        self.photoJob = photoJob
    }
}

/// One painted image of a card, relative to the `FrameStore`.
public struct ArtImage: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Painted, waiting for the birder's approval (photo art only).
        case preview
        case ready
        case failed
    }

    public var path: String?
    public var state: State
    /// Photo art: the original photo it was painted from (the glasses photo or an attached one), relative to the
    /// `FrameStore`. The original is a file of its own and never written over.
    public var source: String?
    /// The painting's key on the art CDN (`art/<sub>/…`), as its job named it (issue #70): what the sighting's find
    /// shows once the card does. Nil for art landed before #70 and for anything not painted on the server.
    public var serverKey: String?

    public init(path: String?, state: State, source: String? = nil, serverKey: String? = nil) {
        self.path = path
        self.state = state
        self.source = source
        self.serverKey = serverKey
    }
}

/// A stored request to paint art for a card. Nothing acts on it since #137.
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
    /// Photo art: the original photo the job paints from, relative to the `FrameStore`.
    public var source: String?

    public init(id: UUID, kind: Kind, state: State, attempts: Int, source: String? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.attempts = attempts
        self.source = source
    }
}

/// How the album moves between schema versions: a lightweight stage to schema 2; to schema 3 a custom stage that gives
/// every sighting its own identifier and the method Heard (a column default would give them all the same identifier);
/// a lightweight stage to schema 4, whose new column's default is right for every sighting there is; and a lightweight
/// stage to schema 5, which adds the captures and leaves the sightings alone.
public enum AlbumMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [AlbumSchemaV1.self, AlbumSchemaV2.self, AlbumSchemaV3.self, AlbumSchemaV4.self, AlbumSchemaV5.self] }
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
            .lightweight(fromVersion: AlbumSchemaV3.self, toVersion: AlbumSchemaV4.self),
            .lightweight(fromVersion: AlbumSchemaV4.self, toVersion: AlbumSchemaV5.self),
        ]
    }
}

/// The album's persistent schema and container factory.
public enum AlbumSchema {
    public static let models: [any PersistentModel.Type] = AlbumSchemaV5.models

    /// The app's album: on disk in the default store, migrated through `AlbumMigrationPlan`; or in memory.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(isStoredInMemoryOnly: inMemory))
    }

    /// An album at `url`, for tests that open the same file under different schema versions.
    public static func makeContainer(at url: URL) throws -> ModelContainer {
        try makeContainer(ModelConfiguration(url: url))
    }

    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: AlbumSchemaV5.self), migrationPlan: AlbumMigrationPlan.self, configurations: [configuration])
    }
}

extension Sighting {
    /// The album's order (issue #11): newest first.
    public static func newestFirst() -> FetchDescriptor<Sighting> {
        FetchDescriptor<Sighting>(sortBy: [SortDescriptor(\.confirmedAt, order: .reverse)])
    }

    /// The scientific name half of the BirdNET label; the whole label when it has no underscore.
    public var scientificName: String { Self.scientificName(ofLabel: speciesID) }

    /// The scientific name half of a BirdNET label, e.g. "Haemorhous mexicanus" of "Haemorhous mexicanus_House Finch".
    public static func scientificName(ofLabel label: String) -> String { String(label.prefix { $0 != "_" }) }

    /// Every file on disk the sighting refers to, relative to the `FrameStore`: the glasses photo, the attached
    /// originals and the painted art. What goes when the sighting does.
    public var filePaths: [String] {
        [frameImagePath].compactMap { $0 } + attachedPhotoPaths + [art.scene?.path, art.photo?.path, art.photoPreview?.path].compactMap { $0 }
    }

    /// The common name half of the BirdNET label, so a species the pack lacks still has a name (spec user story 40).
    public var commonName: String {
        guard let underscore = speciesID.firstIndex(of: "_") else { return speciesID }
        return String(speciesID[speciesID.index(after: underscore)...])
    }
}

extension Capture {
    /// The captures waiting for a name, newest first, as the album lists its sightings.
    public static func newestFirst() -> FetchDescriptor<Capture> {
        FetchDescriptor<Capture>(sortBy: [SortDescriptor(\.takenAt, order: .reverse)])
    }
}

extension Coordinate {
    /// Degrees with hemispheres to two decimals, e.g. "34.05° N, 118.24° W": the place line when there is no
    /// place name.
    public var formatted: String { formatted(locale: .current) }

    /// `fractionDigits` 1 is about 11 km: a coarse place while no name has arrived (issue #53).
    public func formatted(fractionDigits: Int = 2, locale: Locale) -> String {
        let degrees = FloatingPointFormatStyle<Double>.number.locale(locale).precision(.fractionLength(fractionDigits))
        let lat = "\(abs(latitude).formatted(degrees))° \(latitude < 0 ? "S" : "N")"
        let lon = "\(abs(longitude).formatted(degrees))° \(longitude < 0 ? "W" : "E")"
        return "\(lat), \(lon)"
    }
}
