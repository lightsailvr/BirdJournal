import Foundation
import Testing
@testable import Pack

/// Lookups by key (issue #208): a species by its scientific name, a photo and a sound by id, in one pack and across the
/// packs on the phone, answer as a scan of the lists in their order does, at the size the bundled pack is about to have.
@Suite("Pack lookups")
@MainActor
struct PackLookupTests {
    @Test("a pack of 300 species finds every species, photo and sound a scan of its lists finds, and nothing a scan doesn't")
    func aLargePackAnswersAsAScanDoes() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try Self.largePack(root: root)

        #expect(pack.species.count == 302, "the fixture's two and the 300 written here")
        #expect(pack.photos.count == 903 && pack.sounds.count == 601)
        for species in pack.species {
            #expect(pack.species(scientificName: species.scientificName) == Self.scan(pack, species: species.scientificName))
            #expect(pack.species(scientificName: species.scientificName)?.id == species.id)
        }
        for photo in pack.photos {
            #expect(pack.photo(id: photo.id) == Self.scan(pack, photo: photo.id))
            #expect(pack.photo(id: photo.id)?.inatPhotoID == photo.inatPhotoID)
        }
        for sound in pack.sounds {
            #expect(pack.sound(id: sound.id) == Self.scan(pack, sound: sound.id))
            #expect(pack.sound(id: sound.id)?.file == sound.file)
        }
        // Keys no list holds, and each kind of key asked of the other lists.
        let strangers = ["", "Nope nope", "Genus species300 ", "genus species300", "Genus species301", "genus-species-300", "inat-0", "inat-100301", "xc-0", "xc-10301", "xc-1 "]
        for key in strangers + [pack.species[150].id, pack.photos[450].id, pack.sounds[300].id] {
            #expect(pack.species(scientificName: key) == Self.scan(pack, species: key), "\(key)")
            #expect(pack.photo(id: key) == Self.scan(pack, photo: key), "\(key)")
            #expect(pack.sound(id: key) == Self.scan(pack, sound: key), "\(key)")
        }
        #expect(pack.species(scientificName: "Genus species300")?.commonName == "Bird 300")
        #expect(pack.photo(id: "inat-100300")?.speciesID == "genus-species-300" && pack.photo(id: "inat-100300")?.rank == 0)
        #expect(pack.sound(id: "xc-20300")?.speciesID == "genus-species-300" && pack.sound(id: "xc-20300")?.kind == .call)
        #expect(pack.species(scientificName: "Genus species301") == nil && pack.photo(id: "xc-20300") == nil && pack.sound(id: "inat-100300") == nil)
    }

    @Test("across the packs on the phone, a lookup answers from the first pack a scan of them in order finds it in")
    func theLibraryAnswersAsAScanOfItsPacksDoes() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = try Self.largePack(root: root)
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: root.appending(path: "index.json"))
        let packs = library.packs
        #expect(packs.map(\.info.id) == [PackIndex.bundledPackID, "test-pack"])
        #expect(packs.last?.species == large.species)

        // Black Phoebe and Anna's Hummingbird are in both packs; the 300 written here only in the download.
        let names = packs.flatMap { $0.species.map(\.scientificName) } + ["Nope nope", ""]
        #expect(names.count > 450)
        for name in names {
            let scanned = packs.lazy.compactMap { pack in Self.scan(pack, species: name).map { (pack, $0) } }.first
            let found = library.species(scientificName: name)
            #expect(found?.pack.info.id == scanned?.0.info.id && found?.species == scanned?.1, "\(name)")
        }
        for id in packs.flatMap({ $0.photos.map(\.id) }) + ["inat-0", "xc-1"] {
            let scanned = packs.lazy.compactMap { pack in Self.scan(pack, photo: id).map { (pack, $0) } }.first
            let found = library.photo(id: id)
            #expect(found?.pack.info.id == scanned?.0.info.id && found?.photo == scanned?.1, "\(id)")
        }
        for id in packs.flatMap({ $0.sounds.map(\.id) }) + ["xc-0", "inat-1"] {
            let scanned = packs.lazy.compactMap { pack in Self.scan(pack, sound: id).map { (pack, $0) } }.first
            let found = library.sound(id: id)
            #expect(found?.pack.info.id == scanned?.0.info.id && found?.sound == scanned?.1, "\(id)")
        }
        #expect(library.species(scientificName: "Sayornis nigricans")?.pack.info.id == PackIndex.bundledPackID)
        #expect(library.species(scientificName: "Genus species7")?.pack.info.id == "test-pack")
        #expect(library.photo(id: "inat-200007")?.pack.info.id == "test-pack" && library.sound(id: "xc-10007")?.pack.info.id == "test-pack")
    }

    // MARK: - The scans the lookups replaced: the first match in the pack's order.

    private static func scan(_ pack: SpeciesPack, species scientificName: String) -> PackSpecies? {
        for species in pack.species where species.scientificName == scientificName { return species }
        return nil
    }

    private static func scan(_ pack: SpeciesPack, photo id: String) -> PackPhoto? {
        for species in pack.species {
            for photo in species.photos where photo.id == id { return photo }
        }
        return nil
    }

    private static func scan(_ pack: SpeciesPack, sound id: String) -> PackSound? {
        for species in pack.species {
            for sound in species.sounds where sound.id == id { return sound }
        }
        return nil
    }

    /// The fixture pack installed under `root` with 300 more species written into its database, each with three photos and
    /// a song and a call: the rows a lookup reads, without the files behind them.
    private static func largePack(root: URL) throws -> SpeciesPack {
        let installed = try PackSetTests.install("test-pack", root: root)
        try PackPatchTests.exec(installed.directory, """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300)
            INSERT INTO species (id, scientific_name, common_name, birdnet_label, sort_order)
                SELECT 'genus-species-' || i, 'Genus species' || i, 'Bird ' || i, 'Genus species' || i || '_Bird ' || i, 1 + i FROM n;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300), r(rank) AS (VALUES (0), (1), (2))
            INSERT INTO photo (id, species_id, rank, file_lens, file_phone, observer, observer_login, license, credit_line, short_credit, source_url, photo_url, inat_photo_id, score)
                SELECT 'inat-' || (100000 * (rank + 1) + i), 'genus-species-' || i, rank, 'lens/' || (100000 * (rank + 1) + i) || '.jpg', 'phone/' || (100000 * (rank + 1) + i) || '.jpg',
                       'Jane Birder', 'jbirder', 'CC0', 'Jane Birder, no rights reserved (CC0)', 'Photo: Jane Birder, CC0',
                       'https://www.inaturalist.org/observations/' || (100000 * (rank + 1) + i),
                       'https://inaturalist-open-data.s3.amazonaws.com/photos/' || (100000 * (rank + 1) + i) || '/original.jpg', 100000 * (rank + 1) + i, 0.5 - rank * 0.1
                FROM n, r;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300), r(rank, kind) AS (VALUES (0, 'song'), (1, 'call'))
            INSERT INTO sound (id, species_id, rank, kind, file, duration_ms, recordist, license, credit_line, short_credit, source_url, quality)
                SELECT 'xc-' || (10000 * (rank + 1) + i), 'genus-species-' || i, rank, kind, 'sounds/xc-' || (10000 * (rank + 1) + i) || '.m4a', 8000, 'Jane Recordist', 'CC BY-SA 4.0',
                       'Jane Recordist, XC' || (10000 * (rank + 1) + i) || ' (CC BY-SA 4.0)', 'Sound: Jane Recordist, XC' || (10000 * (rank + 1) + i),
                       'https://xeno-canto.org/' || (10000 * (rank + 1) + i), 'A'
                FROM n, r;
            """)
        return try SpeciesPack.open(directory: installed.directory)
    }
}
