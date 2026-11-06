import Foundation
import ImageIO
import Testing
@testable import Pack

/// True silhouettes (issue #150, A3): a pack within schema 5 may carry one per species in a `silhouette` table. A pack without
/// the table, and a species without a row, read as having none, which keeps the app's glyph.
@Suite("PackSilhouette")
@MainActor
struct PackSilhouetteTests {
    @Test("a silhouette reads from its table, with its file, size and path on disk")
    func readsItsRow() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try PackSetTests.install("test-pack", root: root)
        let speciesID = try #require(installed.species.first?.id)
        try PackPatchTests.exec(installed.directory, """
            CREATE TABLE silhouette (species_id TEXT PRIMARY KEY, file TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
                source_photo_ids TEXT NOT NULL, workflow_version TEXT NOT NULL);
            INSERT INTO silhouette VALUES ('\(speciesID)', 'silhouette/\(speciesID).png', 92, 180, '[2]', 'silhouette@1');
            UPDATE pack SET schema_version = 5;
            """)

        let pack = try SpeciesPack.open(directory: installed.directory)
        let silhouette = try #require(pack.species.first?.silhouette)
        #expect(silhouette == PackSilhouette(file: "silhouette/\(speciesID).png", width: 92, height: 180))
        #expect(pack.silhouetteURL(for: silhouette) == installed.directory.appending(path: "silhouette/\(speciesID).png"))
        #expect(pack.species.dropFirst().allSatisfy { $0.silhouette == nil }, "a species without a row keeps the glyph")
    }

    @Test("a schema-5 pack built before silhouettes has no such table, and reads as having none")
    func anOlderPackHasNone() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try PackSetTests.install("test-pack", root: root)
        try PackPatchTests.exec(installed.directory, """
            CREATE TABLE patch (species_id TEXT PRIMARY KEY, file TEXT NOT NULL, layers_file TEXT NOT NULL, width INTEGER NOT NULL,
                height INTEGER NOT NULL, ground TEXT NOT NULL, stitch_bounds TEXT NOT NULL, source_photo_ids TEXT NOT NULL, workflow_version TEXT NOT NULL);
            UPDATE pack SET schema_version = 5;
            """)
        let pack = try SpeciesPack.open(directory: installed.directory)
        #expect(pack.info.schemaVersion == 5)
        #expect(pack.species.allSatisfy { $0.silhouette == nil })
    }

    @Test("Los Angeles carries all 160, each a PNG with an alpha channel on disk")
    func theBundledPack() throws {
        let pack = try SpeciesPack.bundled()
        #expect(pack.species.count == 160)
        #expect(pack.species.allSatisfy { $0.silhouette != nil })
        for species in pack.species.prefix(5) {
            let silhouette = try #require(species.silhouette)
            let url = pack.silhouetteURL(for: silhouette)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url)")
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == silhouette.width && image.height == silhouette.height)
            #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst)
        }
    }
}
