import Foundation
import SQLite3

/// A species pack as `packbuilder` writes it (spec "Pack store"): `pack.sqlite` beside `lens/` and `phone/` JPEG
/// folders and a `LICENSE` listing every credit. The whole database is read once into value types; nothing keeps
/// the SQLite connection open.
public struct SpeciesPack: Sendable, Hashable {
    /// The schema this reader understands; `packbuilder.writer.SCHEMA_VERSION` must match. Schema 2 (issue #12) added
    /// the Wikipedia-derived description columns' source.
    public static let schemaVersion = 2

    public let info: PackInfo
    /// The folder holding `pack.sqlite` and the image folders.
    public let directory: URL
    /// In the pack's order.
    public let species: [PackSpecies]

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

    /// The Creative Commons deed for `license` (the credits screen's license link; the observation page states the
    /// exact terms). Nil for a license the pack builder does not admit.
    public var licenseURL: URL? {
        switch license {
        case "CC0": URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")
        case "CC BY": URL(string: "https://creativecommons.org/licenses/by/4.0/")
        case "CC BY-NC": URL(string: "https://creativecommons.org/licenses/by-nc/4.0/")
        default: nil
        }
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
        guard info.schemaVersion == schemaVersion else { throw PackError.unsupportedSchema(info.schemaVersion) }
        let photosBySpecies = try readPhotos(database)
        let species = try readSpecies(database, photos: photosBySpecies)
        return SpeciesPack(info: info, directory: directory, species: species)
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

    private static func readSpecies(_ database: SQLiteDatabase, photos: [String: [PackPhoto]]) throws -> [PackSpecies] {
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
                photos: photos[id] ?? []
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
