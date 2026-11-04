import Foundation
import SQLite3
import Testing
@testable import Pack

/// Patches (issue #133, of #131): a schema-5 pack carries one embroidered patch per species, its colour and its layers,
/// with its size, ground, stitch layers and source photos; a schema-4 pack reads as having none.
@Suite("PackPatch")
@MainActor
struct PackPatchTests {
    @Test("a schema-5 pack reads each species' patch from its patch table")
    func schemaFivePatches() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try PackSetTests.install("test-pack", root: root)
        let speciesID = try #require(installed.species.first?.id)
        try Self.exec(installed.directory, """
            CREATE TABLE patch (species_id TEXT PRIMARY KEY, file TEXT NOT NULL, layers_file TEXT NOT NULL, width INTEGER NOT NULL,
                height INTEGER NOT NULL, ground TEXT NOT NULL, stitch_bounds TEXT NOT NULL, source_photo_ids TEXT NOT NULL, workflow_version TEXT NOT NULL);
            INSERT INTO patch VALUES ('\(speciesID)', 'patch/\(speciesID).avif', 'patch/\(speciesID)-layers.avif', 680, 720, '#C4A068',
                '[0,26,51,255]', '[2]', 'patch-art@1 patch-prompts@1');
            UPDATE pack SET schema_version = 5;
            """)

        let pack = try SpeciesPack.open(directory: installed.directory)
        #expect(pack.info.schemaVersion == 5)
        let patch = try #require(pack.species.first?.patch)
        #expect(patch == PackPatch(speciesID: speciesID, file: "patch/\(speciesID).avif", layersFile: "patch/\(speciesID)-layers.avif", width: 680, height: 720,
                                   ground: "#C4A068", stitchBounds: [0, 26, 51, 255], sourcePhotoIDs: [2], workflowVersion: "patch-art@1 patch-prompts@1"))
        #expect(pack.patchURL(for: patch) == installed.directory.appending(path: "patch/\(speciesID).avif"))
        #expect(pack.patchLayersURL(for: patch).lastPathComponent == "\(speciesID)-layers.avif")
        #expect(pack.species.dropFirst().allSatisfy { $0.patch == nil }, "a species without a row has no patch")
    }

    @Test("a schema-4 pack has no patches")
    func schemaFourHasNone() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack", root: root)
        #expect(pack.info.schemaVersion == 4)
        #expect(pack.species.allSatisfy { $0.patch == nil })
    }

    static func exec(_ directory: URL, _ sql: String) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.appending(path: "pack.sqlite").path(percentEncoded: false), &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
}
