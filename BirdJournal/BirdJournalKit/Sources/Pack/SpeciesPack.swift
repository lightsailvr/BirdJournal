import Foundation
import SQLite3

/// A species pack as `packbuilder` writes it (spec "Pack store"): `pack.sqlite` beside `lens/` and `phone/` JPEG
/// folders, a `sounds/` folder of reference clips (schema 3), the set definition and the `art/` folder of pack art (schema 4)
/// and a `LICENSE` listing every credit. The whole database is read once into value types; nothing keeps
/// the SQLite connection open.
public struct SpeciesPack: Sendable, Hashable {
    /// The schema `packbuilder.writer.SCHEMA_VERSION` writes. Schema 2 (issue #12) added the Wikipedia-derived
    /// description columns' source; schema 3 (issue #41) the `sound` table and the `sounds/` folder; schema 4 (issue
    /// #54) the set definition and the tables for stats, the fact sheet, lore, pack art, the threatened flag and the
    /// family, which stay empty until the tickets that fill them (an empty table means "not available yet"); issue #55
    /// fills the stats, the threatened flag and the family, issue #57 the pack art and issue #56 the fact sheet and the lore.
    /// Schema 5 (issue #133) added the `patch` table and the `patch/` folder: one embroidered patch per species.
    public static let schemaVersion = 5
    /// The schemas this reader opens: a schema-2 pack downloaded before #41 still reads, without sounds; a schema-3
    /// pack without its set.
    public static let supportedSchemaVersions = 2...schemaVersion

    public let info: PackInfo
    /// The folder holding `pack.sqlite` and the image folders.
    public let directory: URL
    /// In the pack's order.
    public let species: [PackSpecies]
    /// The set the pack's species make (schema 4); nil for an older pack, whose set the index may still know.
    public let set: PackSet?
    /// The set's cover (issue #114), an illustrated landscape for the Atlas and the Listen tab; nil for a pack built
    /// before covers or whose cover isn't approved yet, which the app shows with its designed fallback.
    public let cover: PackCover?

    public func species(scientificName: String) -> PackSpecies? {
        species.first { $0.scientificName == scientificName }
    }

    /// The photo with this pack-wide id (`PackPhoto.id`), if any.
    public func photo(id: String) -> PackPhoto? {
        for entry in species {
            if let photo = entry.photos.first(where: { $0.id == id }) { return photo }
        }
        return nil
    }

    /// Every photo in the pack, in species order then rank: the credits screen's list.
    public var photos: [PackPhoto] { species.flatMap(\.photos) }

    public func lensImageURL(for photo: PackPhoto) -> URL {
        directory.appending(path: photo.lensFile)
    }

    public func phoneImageURL(for photo: PackPhoto) -> URL {
        directory.appending(path: photo.phoneFile)
    }

    /// Every reference sound in the pack, in species order then rank: the credits screen's list.
    public var sounds: [PackSound] { species.flatMap(\.sounds) }

    /// The reference sounds of a species, song first.
    public func sounds(for species: PackSpecies) -> [PackSound] { species.sounds }

    /// The sound with this pack-wide id (`PackSound.id`), if any: what the lens names a clip by.
    public func sound(id: String) -> PackSound? {
        for entry in species {
            if let sound = entry.sounds.first(where: { $0.id == id }) { return sound }
        }
        return nil
    }

    public func soundURL(for sound: PackSound) -> URL {
        directory.appending(path: sound.file)
    }

    public func artURL(for art: PackArt) -> URL {
        directory.appending(path: art.file)
    }

    /// The patch's colour on transparency (AVIF).
    public func patchURL(for patch: PackPatch) -> URL {
        directory.appending(path: patch.file)
    }

    /// The patch's layers (AVIF at half size): its height in red, its cord in green, its stitch order in blue.
    public func patchLayersURL(for patch: PackPatch) -> URL {
        directory.appending(path: patch.layersFile)
    }

    /// The set's cover on disk, when the pack has one.
    public var coverURL: URL? {
        cover.map { directory.appending(path: $0.file) }
    }

    /// The pack's photos a painting was painted from, for its credit; empty for a painting from text.
    public func sourcePhotos(of art: PackArt) -> [PackPhoto] {
        let species = species.first { $0.id == art.speciesID }
        return art.sourcePhotoIDs.compactMap { id in species?.photos.first { $0.inatPhotoID == id } }
    }
}

/// The `pack` row: identity, version and the license text.
public struct PackInfo: Sendable, Hashable {
    public let id: String
    public let name: String
    public let region: String
    public let version: Int
    public let schemaVersion: Int
    public let builtAt: String
    /// The pack's LICENSE text, for the credits screen.
    public let licenseText: String
}

/// One `species` row with its photos. The description fields are cut from the species' Wikipedia article by the pack
/// builder (or written by hand in its override file) and are nil when it had neither.
public struct PackSpecies: Sendable, Hashable, Identifiable {
    public let id: String
    /// The key shared with the acoustic model's labels (`Species.scientificName`).
    public let scientificName: String
    public let commonName: String
    public let birdnetLabel: String
    public let inatTaxonID: Int?
    public let wikipediaURL: URL?
    /// A few sentences for the phone.
    public let summary: String?
    /// One or two sentences of plumage, inside the lens details page's word budget.
    public let fieldMarks: String?
    /// Body length, e.g. "16 cm".
    public let size: String?
    /// The habitat terms the article uses most, e.g. "coast, rivers, water".
    public let habitat: String?
    /// The Wikipedia article revision the text was adapted from (CC BY-SA 4.0); nil when the text is hand-written or absent.
    public let descriptionSource: URL?
    /// Best first.
    public let photos: [PackPhoto]
    /// Song first, then call, or one untyped sound; empty for a schema-2 pack or a species with no usable recording.
    public let sounds: [PackSound]
    /// The card art every card of the species shows until it has its own (issue #57); nil for a pack before it or a
    /// species the maintainer listed as an art gap.
    public let packArt: PackArt?
    /// The species' embroidered patch in this pack's edition (issue #133); nil for a pack before schema 5 or a species
    /// without an approved patch.
    public var patch: PackPatch? = nil
    /// The card stats (issue #55); nil for a pack before schema 4 or one built without them, and for a species the
    /// datasets lack (a known gap of the pack build, listed in its `report.json`).
    public var stats: PackStats? = nil
    /// The card's type line, "Songbird — Finch"; nil where `stats` is nil for want of the table.
    public var typeLine: PackTypeLine? = nil
    /// IUCN Vulnerable, Endangered or Critically Endangered, or on the pack builder's hand list; nil when the pack does
    /// not say (before schema 4, or built without the flag).
    public var isThreatened: Bool? = nil
    /// The fact sheet (issue #56): the stats as short sentences, then sentences of the species' Wikipedia article, in
    /// the pack's order. Lore and captions state nothing that is not on it. Empty for a pack before it.
    public var facts: [PackFact] = []
    /// The reviewed lore and its tagline (issue #56); nil for a pack before it, or lore not approved yet.
    public var lore: PackLore? = nil

    /// Whether the pack has any description text for this species.
    public var isDescribed: Bool {
        [summary, fieldMarks, size, habitat].contains { !($0 ?? "").isEmpty }
    }
}

/// One `photo` row: where its two JPEGs are and whom to credit.
public struct PackPhoto: Sendable, Hashable, Identifiable {
    public let id: String
    public let speciesID: String
    public let rank: Int
    /// Paths relative to the pack directory.
    public let lensFile: String
    public let phoneFile: String
    public let observer: String
    public let observerLogin: String?
    public let license: String
    /// iNaturalist's attribution statement, e.g. "© Name, some rights reserved (CC BY-NC)".
    public let creditLine: String
    /// The one-line lens credit, e.g. "Photo: Name, CC BY-NC".
    public let shortCredit: String
    /// The observation page.
    public let sourceURL: URL
    /// The original in the iNaturalist Open Data bucket.
    public let photoURL: URL
    public let inatPhotoID: Int
    public let score: Double

    public init(
        id: String, speciesID: String, rank: Int, lensFile: String, phoneFile: String, observer: String, observerLogin: String?,
        license: String, creditLine: String, shortCredit: String, sourceURL: URL, photoURL: URL, inatPhotoID: Int, score: Double
    ) {
        self.id = id
        self.speciesID = speciesID
        self.rank = rank
        self.lensFile = lensFile
        self.phoneFile = phoneFile
        self.observer = observer
        self.observerLogin = observerLogin
        self.license = license
        self.creditLine = creditLine
        self.shortCredit = shortCredit
        self.sourceURL = sourceURL
        self.photoURL = photoURL
        self.inatPhotoID = inatPhotoID
        self.score = score
    }

    /// The Creative Commons deed for `license` (the credits screen's license link; the observation page states the
    /// exact terms). Nil for a license the pack builder does not admit.
    public var licenseURL: URL? {
        switch license {
        case "CC0": URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")
        case "CC BY": URL(string: "https://creativecommons.org/licenses/by/4.0/")
        case "CC BY-SA": URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")
        case "CC BY-NC": URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")
        default: nil
        }
    }
}

/// One `patch` row (issue #133, of #131): the species' embroidered patch in the pack's edition, an AI illustration
/// (ADR-0007) reviewed before the pack shipped, with what the app lights and stitches it from.
public struct PackPatch: Sendable, Hashable {
    public let speciesID: String
    /// The colour on transparency, e.g. `patch/haemorhous-mexicanus.avif`, `width` × `height` (720 on its longest side).
    public let file: String
    /// The layers at half size: height (thread relief and the raised cord) in red, the cord's mask in green, the stitch
    /// order (0...255, one thread colour at a time, the cord last) in blue.
    public let layersFile: String
    public let width: Int
    public let height: Int
    /// The bare twill's colour, "#RRGGBB": what an unstitched pattern shows.
    public let ground: String
    /// Where each stitch layer starts on the order's 0...255, the last being 255.
    public let stitchBounds: [Int]
    /// The iNaturalist ids of the pack photos its reference bird came from.
    public let sourcePhotoIDs: [Int]
    /// The workflow and prompts versions, e.g. "patch-art@1 patch-prompts@1".
    public let workflowVersion: String

    public init(speciesID: String, file: String, layersFile: String, width: Int, height: Int, ground: String, stitchBounds: [Int], sourcePhotoIDs: [Int], workflowVersion: String) {
        self.speciesID = speciesID
        self.file = file
        self.layersFile = layersFile
        self.width = width
        self.height = height
        self.ground = ground
        self.stitchBounds = stitchBounds
        self.sourcePhotoIDs = sourcePhotoIDs
        self.workflowVersion = workflowVersion
    }
}

/// One `pack_art` row (issue #57): the species' painting, an AI illustration (ADR-0007) reviewed before the pack
/// shipped, and what it was painted from.
public struct PackArt: Sendable, Hashable {
    public let speciesID: String
    /// Path relative to the pack directory, e.g. `art/haemorhous-mexicanus.avif` (864 × 1152, 3:4).
    public let file: String
    /// The iNaturalist ids of the pack photos it was painted from (`PackPhoto.inatPhotoID`); empty for a painting
    /// from text, for a species with no open-license photo.
    public let sourcePhotoIDs: [Int]
    /// The workflow, isolation and prompts versions, e.g. "pack-art@3 bird-isolate@1 prompts@9".
    public let workflowVersion: String

    public init(speciesID: String, file: String, sourcePhotoIDs: [Int], workflowVersion: String) {
        self.speciesID = speciesID
        self.file = file
        self.sourcePhotoIDs = sourcePhotoIDs
        self.workflowVersion = workflowVersion
    }
}

/// The `cover` row (issue #114): the set's cover, an AI illustration of its edition theme painted from text alone (no
/// photo, no place) and reviewed before the pack shipped. It is illustrative: never a map or evidence of where a bird
/// was seen. The pack's LICENSE credits it under "Set cover".
public struct PackCover: Sendable, Hashable {
    /// Path relative to the pack directory: `cover.avif` (1536 × 864, 16:9; the app crops it from the middle).
    public let file: String
    /// The workflow and prompts versions, e.g. "set-cover@1 cover-prompts@1".
    public let workflowVersion: String
    /// The seed it was painted with, for the credit.
    public let seed: Int
    /// The model that painted it, e.g. "FLUX.3 Image Klein".
    public let model: String

    public init(file: String, workflowVersion: String, seed: Int, model: String) {
        self.file = file
        self.workflowVersion = workflowVersion
        self.seed = seed
        self.model = model
    }
}

/// A set's cover where the phone has it (issue #114): `PackLibrary.cover(setID:)`.
public enum SetCover: Sendable, Hashable {
    /// The full cover that ships with the app (issue #150), and its file.
    case bundled(PackCover, URL)
    /// The full cover of the pack on the phone, and its file.
    case pack(PackCover, URL)
    /// The index's thumbnail, before the pack is downloaded.
    case thumbnail(PackIndexCover)

    /// The credit for the credits screen, labelled as illustration: "AI illustration: FLUX.3 Image Klein, set-cover@1 cover-prompts@1, seed 42".
    public var credit: String {
        switch self {
        case let .bundled(cover, _), let .pack(cover, _): "AI illustration: \(cover.model), \(cover.workflowVersion), seed \(cover.seed)"
        case let .thumbnail(cover): "AI illustration: \(cover.model), \(cover.workflowVersion), seed \(cover.seed)"
        }
    }
}

/// What ships with the app for every set (issue #150): its approved painting and its definition, so Listen shows the painting
/// for the place before the set's pack is on the phone, on a phone that has never been online. `packbuilder bundle-covers` writes
/// them, with `covers.json`, into this target's `Covers` folder.
public struct BundledCovers: Sendable {
    /// The sets as they shipped, for the sets nothing newer describes.
    public let sets: [PackSet]
    private let covers: [String: SetCover]

    public init(covers: [String: SetCover], sets: [PackSet] = []) {
        self.covers = covers
        self.sets = sets
    }

    public static let none = BundledCovers(covers: [:])

    /// The ones in this build. A folder that can't be read is the same as none: the packs and the index remain.
    public static let shipped: BundledCovers = {
        struct Entry: Decodable {
            let file: String
            let set: String
            let model: String
            let workflowVersion: String
            let seed: Int
        }
        guard let manifest = Bundle.module.url(forResource: "covers", withExtension: "json", subdirectory: "Covers"),
              let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return .none }
        let folder = manifest.deletingLastPathComponent()
        return BundledCovers(
            covers: entries.mapValues { entry in
                .bundled(PackCover(file: entry.file, workflowVersion: entry.workflowVersion, seed: entry.seed, model: entry.model), folder.appending(path: entry.file))
            },
            sets: entries.keys.sorted().compactMap { id in
                (try? Data(contentsOf: folder.appending(path: entries[id]!.set))).flatMap { try? PackSet.decode(from: $0) }
            }
        )
    }()

    public func cover(setID: String) -> SetCover? {
        covers[setID]
    }
}

/// One fact-sheet entry (issue #56): a short sentence and where it comes from.
public struct PackFact: Sendable, Hashable {
    public let rank: Int
    public let text: String
    /// The Wikipedia article revision as a permanent link, or the dataset's key ("avonet", "birdbase", "wingspan").
    public let source: String

    public init(rank: Int, text: String, source: String) {
        self.rank = rank
        self.text = text
        self.source = source
    }

    /// The Wikipedia revision this fact was taken from; nil for a dataset's.
    public var wikipediaRevision: URL? { source.hasPrefix("https://") ? URL(string: source) : nil }
    /// The dataset this fact was told from; nil for an article's.
    public var dataset: PackStats.Source? { PackStats.Source(rawValue: source) }
}

/// One `lore` row (issue #56): 50 to 80 words of myth-voiced lore and a tagline of 12 words or fewer, written by a
/// Claude model from the fact sheet alone and reviewed by hand. CC BY-SA 4.0 as an adaptation of the Wikipedia text.
public struct PackLore: Sendable, Hashable {
    public let text: String
    public let tagline: String
    /// The sources of the facts it cites, in sheet order: Wikipedia revision links and dataset keys.
    public let sources: [String]
    /// The story title (issue #113): 2 to 5 words heading the lore on the card front ("The Waterside Mason"), written
    /// and reviewed like the lore. Nil when it is not approved yet, and in a pack built before titles.
    public let title: String?

    public init(text: String, tagline: String, sources: [String], title: String? = nil) {
        self.text = text
        self.tagline = tagline
        self.sources = sources
        self.title = title
    }

    /// The Wikipedia revision its facts came from, for the credit; nil when it rests on the datasets alone.
    public var wikipediaRevision: URL? { sources.first { $0.hasPrefix("https://") }.flatMap(URL.init(string:)) }
    /// The datasets its facts came from.
    public var datasets: [PackStats.Source] { sources.compactMap(PackStats.Source.init(rawValue:)) }
}

/// One `sound` row (issue #41): an 8 s reference clip of the species, where it is and whom to credit.
public struct PackSound: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case song
        case call
        /// A recording its source does not type (iNaturalist), used only when xeno-canto had neither a song nor a call.
        case sound
    }

    /// `xc-<number>` or `inat-<sound id>`.
    public let id: String
    public let speciesID: String
    public let rank: Int
    public let kind: Kind
    /// Path relative to the pack directory, e.g. `sounds/xc-109602.m4a` (AAC, mono, 48 kHz).
    public let file: String
    public let duration: Duration
    public let recordist: String
    /// With its version, e.g. "CC BY-NC-SA 4.0" or "CC0".
    public let license: String
    /// Recordist, catalogue number, the recording's page and the license, as xeno-canto asks.
    public let creditLine: String
    /// The line beside the play control, e.g. "Sound: Name, XC109602".
    public let shortCredit: String
    /// The recording's page on xeno-canto or its iNaturalist observation.
    public let sourceURL: URL
    /// xeno-canto's grade, A (best) to E; nil when unrated.
    public let quality: String?

    public init(
        id: String, speciesID: String, rank: Int, kind: Kind, file: String, duration: Duration, recordist: String, license: String,
        creditLine: String, shortCredit: String, sourceURL: URL, quality: String?
    ) {
        self.id = id
        self.speciesID = speciesID
        self.rank = rank
        self.kind = kind
        self.file = file
        self.duration = duration
        self.recordist = recordist
        self.license = license
        self.creditLine = creditLine
        self.shortCredit = shortCredit
        self.sourceURL = sourceURL
        self.quality = quality
    }

    /// The Creative Commons deed for `license` ("CC BY-NC-SA 4.0" → .../licenses/by-nc-sa/4.0/); nil for a license the
    /// pack builder does not admit.
    public var licenseURL: URL? {
        if license == "CC0" { return URL(string: "https://creativecommons.org/publicdomain/zero/1.0/") }
        let parts = license.split(separator: " ")
        guard parts.count == 3, parts[0] == "CC", ["BY", "BY-SA", "BY-NC", "BY-NC-SA"].contains(parts[1]) else { return nil }
        return URL(string: "https://creativecommons.org/licenses/\(parts[1].lowercased())/\(parts[2])/")
    }
}

/// Why a pack could not be read.
public enum PackError: Error, Equatable {
    case missingDatabase(String)
    case missingBundledPack(String)
    /// A pack id the library no longer has (deleted while a screen still pointed at it).
    case notInstalled(String)
    case unsupportedSchema(Int)
    case sqlite(String)
    case malformedRow(table: String)
}

extension SpeciesPack {
    /// Reads the pack in `directory`.
    public static func open(directory: URL) throws -> SpeciesPack {
        let databaseURL = directory.appending(path: "pack.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            throw PackError.missingDatabase(databaseURL.path(percentEncoded: false))
        }
        let database = try SQLiteDatabase(path: databaseURL.path(percentEncoded: false))
        defer { database.close() }

        let info = try readInfo(database)
        guard supportedSchemaVersions.contains(info.schemaVersion) else { throw PackError.unsupportedSchema(info.schemaVersion) }
        let photosBySpecies = try readPhotos(database)
        let soundsBySpecies = info.schemaVersion >= 3 ? try readSounds(database) : [:]
        let artBySpecies = info.schemaVersion >= 4 ? try readPackArt(database) : [:]
        var species = try readSpecies(database, photos: photosBySpecies, sounds: soundsBySpecies, art: artBySpecies)
        let set = info.schemaVersion >= 4 ? try readSet(database) : nil
        if info.schemaVersion >= 4 {
            let stats = try readStats(database)
            let typeLines = try readTypeLines(database)
            let threatened = try readThreatened(database)
            let facts = try readFacts(database)
            let lore = try readLore(database)
            for index in species.indices {
                let id = species[index].id
                species[index].stats = stats[id]
                species[index].typeLine = typeLines[id]
                species[index].isThreatened = threatened[id]
                species[index].facts = facts[id] ?? []
                species[index].lore = lore[id]
            }
        }
        if info.schemaVersion >= 5 {
            let patches = try readPatches(database)
            for index in species.indices { species[index].patch = patches[species[index].id] }
        }
        let cover = info.schemaVersion >= 4 ? try readCover(database) : nil
        return SpeciesPack(info: info, directory: directory, species: species, set: set, cover: cover)
    }

    /// The pack compiled into the package's `Packs` resource folder (the symlink to the repo's `packs/` directory).
    public static func bundled(id: String = PackIndex.bundledPackID) throws -> SpeciesPack {
        guard let directory = Bundle.module.url(forResource: id, withExtension: nil, subdirectory: "Packs") else {
            throw PackError.missingBundledPack(id)
        }
        return try open(directory: directory)
    }

    private static func readInfo(_ database: SQLiteDatabase) throws -> PackInfo {
        let rows = try database.rows("SELECT id, name, region, version, schema_version, built_at, license_text FROM pack") { row in
            guard let id = row.text(0), let name = row.text(1), let region = row.text(2), let version = row.int(3),
                  let schemaVersion = row.int(4), let builtAt = row.text(5), let license = row.text(6)
            else { throw PackError.malformedRow(table: "pack") }
            return PackInfo(id: id, name: name, region: region, version: version, schemaVersion: schemaVersion, builtAt: builtAt, licenseText: license)
        }
        guard rows.count == 1, let info = rows.first else { throw PackError.malformedRow(table: "pack") }
        return info
    }

    private static func readPhotos(_ database: SQLiteDatabase) throws -> [String: [PackPhoto]] {
        let sql = """
            SELECT id, species_id, rank, file_lens, file_phone, observer, observer_login, license, credit_line, short_credit,
                   source_url, photo_url, inat_photo_id, score
            FROM photo ORDER BY species_id, rank
            """
        let photos = try database.rows(sql) { row in
            guard let id = row.text(0), let speciesID = row.text(1), let rank = row.int(2), let lens = row.text(3),
                  let phone = row.text(4), let observer = row.text(5), let license = row.text(7), let credit = row.text(8),
                  let short = row.text(9), let source = row.text(10).flatMap(URL.init(string:)),
                  let photoURL = row.text(11).flatMap(URL.init(string:)), let inatPhotoID = row.int(12), let score = row.double(13)
            else { throw PackError.malformedRow(table: "photo") }
            return PackPhoto(
                id: id, speciesID: speciesID, rank: rank, lensFile: lens, phoneFile: phone, observer: observer,
                observerLogin: row.text(6), license: license, creditLine: credit, shortCredit: short, sourceURL: source,
                photoURL: photoURL, inatPhotoID: inatPhotoID, score: score
            )
        }
        return Dictionary(grouping: photos, by: \.speciesID)
    }

    private static func readSounds(_ database: SQLiteDatabase) throws -> [String: [PackSound]] {
        let sql = """
            SELECT id, species_id, rank, kind, file, duration_ms, recordist, license, credit_line, short_credit, source_url, quality
            FROM sound ORDER BY species_id, rank
            """
        let sounds = try database.rows(sql) { row in
            guard let id = row.text(0), let speciesID = row.text(1), let rank = row.int(2), let kind = row.text(3).flatMap(PackSound.Kind.init(rawValue:)),
                  let file = row.text(4), let durationMS = row.int(5), let recordist = row.text(6), let license = row.text(7),
                  let credit = row.text(8), let short = row.text(9), let source = row.text(10).flatMap(URL.init(string:))
            else { throw PackError.malformedRow(table: "sound") }
            return PackSound(
                id: id, speciesID: speciesID, rank: rank, kind: kind, file: file, duration: .milliseconds(durationMS), recordist: recordist,
                license: license, creditLine: credit, shortCredit: short, sourceURL: source, quality: row.text(11)
            )
        }
        return Dictionary(grouping: sounds, by: \.speciesID)
    }

    /// Each species' `pack_art` row, by species id; empty for a pack built without art.
    private static func readPackArt(_ database: SQLiteDatabase) throws -> [String: PackArt] {
        let rows = try database.rows("SELECT species_id, file, source_photo_ids, workflow_version FROM pack_art") { row in
            guard let speciesID = row.text(0), let file = row.text(1), let ids = row.text(2),
                  let sourcePhotoIDs = try? JSONDecoder().decode([Int].self, from: Data(ids.utf8)), let workflow = row.text(3)
            else { throw PackError.malformedRow(table: "pack_art") }
            return PackArt(speciesID: speciesID, file: file, sourcePhotoIDs: sourcePhotoIDs, workflowVersion: workflow)
        }
        return Dictionary(rows.map { ($0.speciesID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Each species' `patch` row, by species id.
    private static func readPatches(_ database: SQLiteDatabase) throws -> [String: PackPatch] {
        let sql = "SELECT species_id, file, layers_file, width, height, ground, stitch_bounds, source_photo_ids, workflow_version FROM patch"
        let rows = try database.rows(sql) { row in
            guard let speciesID = row.text(0), let file = row.text(1), let layers = row.text(2), let width = row.int(3), let height = row.int(4),
                  let ground = row.text(5), let bounds = row.text(6), let ids = row.text(7), let workflow = row.text(8),
                  let stitchBounds = try? JSONDecoder().decode([Int].self, from: Data(bounds.utf8)),
                  let sourcePhotoIDs = try? JSONDecoder().decode([Int].self, from: Data(ids.utf8))
            else { throw PackError.malformedRow(table: "patch") }
            return PackPatch(speciesID: speciesID, file: file, layersFile: layers, width: width, height: height, ground: ground,
                             stitchBounds: stitchBounds, sourcePhotoIDs: sourcePhotoIDs, workflowVersion: workflow)
        }
        return Dictionary(rows.map { ($0.speciesID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The one `set_definition` row's JSON; nil while the table is empty.
    private static func readSet(_ database: SQLiteDatabase) throws -> PackSet? {
        let rows = try database.rows("SELECT definition FROM set_definition") { row in
            guard let json = row.text(0), let set = try? PackSet.decode(from: Data(json.utf8)) else { throw PackError.malformedRow(table: "set_definition") }
            return set
        }
        guard rows.count <= 1 else { throw PackError.malformedRow(table: "set_definition") }
        return rows.first
    }

    /// The one `cover` row (issue #114); nil while the table is empty or, in a schema-4 pack built before covers,
    /// absent.
    private static func readCover(_ database: SQLiteDatabase) throws -> PackCover? {
        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cover'") { $0.text(0) }
        guard !tables.isEmpty else { return nil }
        let rows = try database.rows("SELECT file, workflow_version, seed, model FROM cover") { row in
            guard let file = row.text(0), let workflow = row.text(1), let seed = row.int(2), let model = row.text(3) else {
                throw PackError.malformedRow(table: "cover")
            }
            return PackCover(file: file, workflowVersion: workflow, seed: seed, model: model)
        }
        guard rows.count <= 1 else { throw PackError.malformedRow(table: "cover") }
        return rows.first
    }

    /// The `stats` rows by species id. A category this reader doesn't know (a newer builder's) is left off, as a stat
    /// the datasets lack is.
    private static func readStats(_ database: SQLiteDatabase) throws -> [String: PackStats] {
        let sql = """
            SELECT species_id, avibase_id, wingspan_cm, wingspan_predicted, mass_g, diet, habitat, migration, nest, clutch_min, clutch_max,
                   lifestyle, sources
            FROM stats
            """
        let rows = try database.rows(sql) { row in
            guard let speciesID = row.text(0), let sources = row.text(12).flatMap({ try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) else {
                throw PackError.malformedRow(table: "stats")
            }
            let clutch: ClosedRange<Double>? = switch (row.double(9), row.double(10)) {
            case let (low?, high?) where low <= high: low...high
            case let (low?, nil): low...low
            case let (nil, high?): high...high
            default: nil
            }
            let stats = PackStats(
                avibaseID: row.text(1),
                wingspan: row.double(2).map { PackStats.Wingspan(centimetres: $0, isPredicted: row.int(3) == 1) },
                massGrams: row.double(4),
                diet: row.text(5).flatMap(PackStats.Diet.init(rawValue:)),
                habitat: row.text(6).flatMap(PackStats.Habitat.init(rawValue:)),
                migration: row.text(7).flatMap(PackStats.Migration.init(rawValue:)),
                nests: (row.text(8) ?? "").split(separator: ",").compactMap { PackStats.Nest(rawValue: String($0)) },
                clutch: clutch,
                lifestyle: row.text(11).flatMap(PackStats.Lifestyle.init(rawValue:)),
                sources: sources.compactMap(PackStats.Source.init(rawValue:))
            )
            return (speciesID, stats)
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readTypeLines(_ database: SQLiteDatabase) throws -> [String: PackTypeLine] {
        let rows = try database.rows("SELECT species_id, order_name, family, group_word, family_word FROM family") { row in
            guard let speciesID = row.text(0), let order = row.text(1), let family = row.text(2), let group = row.text(3), let word = row.text(4) else {
                throw PackError.malformedRow(table: "family")
            }
            return (speciesID, PackTypeLine(order: order, family: family, groupWord: group, familyWord: word))
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readThreatened(_ database: SQLiteDatabase) throws -> [String: Bool] {
        let rows = try database.rows("SELECT species_id, threatened FROM threatened") { row in
            guard let speciesID = row.text(0), let threatened = row.int(1) else { throw PackError.malformedRow(table: "threatened") }
            return (speciesID, threatened != 0)
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readFacts(_ database: SQLiteDatabase) throws -> [String: [PackFact]] {
        let facts = try database.rows("SELECT species_id, rank, text, source FROM fact ORDER BY species_id, rank") { row in
            guard let speciesID = row.text(0), let rank = row.int(1), let text = row.text(2), let source = row.text(3) else {
                throw PackError.malformedRow(table: "fact")
            }
            return (speciesID, PackFact(rank: rank, text: text, source: source))
        }
        return Dictionary(grouping: facts, by: \.0).mapValues { $0.map(\.1) }
    }

    /// The lore rows; `title` is a nullable column added within schema 4 (issue #113), so a pack built before it
    /// has none and reads as untitled.
    private static func readLore(_ database: SQLiteDatabase) throws -> [String: PackLore] {
        let columns = Set(try database.rows("SELECT name FROM pragma_table_info('lore')") { $0.text(0) }.compactMap { $0 })
        let title = columns.contains("title") ? "title" : "NULL"
        let rows = try database.rows("SELECT species_id, text, tagline, sources, \(title) FROM lore") { row in
            guard let speciesID = row.text(0), let text = row.text(1), let tagline = row.text(2),
                  let sources = row.text(3).flatMap({ try? JSONDecoder().decode([String].self, from: Data($0.utf8)) })
            else { throw PackError.malformedRow(table: "lore") }
            return (speciesID, PackLore(text: text, tagline: tagline, sources: sources, title: row.text(4)))
        }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private static func readSpecies(
        _ database: SQLiteDatabase, photos: [String: [PackPhoto]], sounds: [String: [PackSound]], art: [String: PackArt]
    ) throws -> [PackSpecies] {
        let sql = """
            SELECT id, scientific_name, common_name, birdnet_label, inat_taxon_id, wikipedia_url, summary, field_marks, size, habitat,
                   description_source
            FROM species ORDER BY sort_order
            """
        return try database.rows(sql) { row in
            guard let id = row.text(0), let scientific = row.text(1), let common = row.text(2), let label = row.text(3) else {
                throw PackError.malformedRow(table: "species")
            }
            return PackSpecies(
                id: id, scientificName: scientific, commonName: common, birdnetLabel: label,
                inatTaxonID: row.int(4), wikipediaURL: row.text(5).flatMap(URL.init(string:)),
                summary: row.text(6), fieldMarks: row.text(7), size: row.text(8), habitat: row.text(9),
                descriptionSource: row.text(10).flatMap(URL.init(string:)),
                photos: photos[id] ?? [], sounds: sounds[id] ?? [], packArt: art[id]
            )
        }
    }
}

/// The least of SQLite needed to read a pack: open read-only, run a query, map rows, close.
private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw PackError.sqlite(message)
        }
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    func rows<T>(_ sql: String, _ map: (Row) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PackError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: results.append(try map(Row(statement: statement)))
            case SQLITE_DONE: return results
            default: throw PackError.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// One result row; every accessor returns nil for SQL NULL.
    struct Row {
        let statement: OpaquePointer

        private func isNull(_ column: Int) -> Bool { sqlite3_column_type(statement, Int32(column)) == SQLITE_NULL }

        func text(_ column: Int) -> String? {
            guard let pointer = sqlite3_column_text(statement, Int32(column)) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int) -> Int? { isNull(column) ? nil : Int(sqlite3_column_int64(statement, Int32(column))) }

        func double(_ column: Int) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, Int32(column)) }
    }
}
