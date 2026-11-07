import Foundation
import Pack
import SQLite3
import Testing
@testable import BirdJournal

@Suite("Guild patch illustrations")
@MainActor
struct GuildPatchArtworkTests {
    private static let goose = "Branta canadensis"

    @Test("Canada Goose uses its available LA patch for missing, unpainted and unavailable editions", arguments: [nil, "us-ca-sd", "not-on-this-phone"] as [String?])
    func gooseFallback(edition: String?) throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: folder))
        let artwork = library.guildPatchArtwork(scientificName: Self.goose, setID: edition)
        #expect(artwork.setID == "us-ca-la")
        #expect(artwork.state.art == library.patchArt(scientificName: Self.goose, setID: "us-ca-la"))
        #expect(artwork.note == "Showing Citrus edition artwork")
        // This correction never changes the viewer's own patch, or claims the find happened in LA.
        #expect(library.patchArt(scientificName: Self.goose, setID: edition) == nil)
    }

    @Test("an installed edition without patches also falls back; an edition with a patch always wins")
    func installedEditions() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundled = try SpeciesPack.bundled()
        try installMetadata(from: bundled, id: "us-ca-sd", into: folder, hasPatches: false)
        var library = PackLibrary(bundled: bundled, storage: PackStorage(directory: folder))
        #expect(library.pack(id: "us-ca-sd") != nil)
        #expect(library.guildPatchArtwork(scientificName: Self.goose, setID: "us-ca-sd").setID == "us-ca-la")
        #expect(library.guildPatchArtwork(scientificName: Self.goose, setID: "us-ca-la").note == nil)
        try FileManager.default.removeItem(at: folder.appending(path: "us-ca-sd"))
        try installMetadata(from: bundled, id: "us-ca-sd", into: folder, hasPatches: true)
        library = PackLibrary(bundled: bundled, storage: PackStorage(directory: folder))
        let exact = library.guildPatchArtwork(scientificName: Self.goose, setID: "us-ca-sd")
        #expect(exact.setID == "us-ca-sd", "the shared edition wins even with a bundled painting available")
        #expect(exact.note == nil)
        #expect(exact.state.art == library.patchArt(scientificName: Self.goose, setID: "us-ca-sd"))
    }

    @Test("fallback prefers bundled artwork, then downloaded IDs in stable order")
    func fallbackOrder() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundled = try SpeciesPack.bundled()
        try installMetadata(from: bundled, id: "z-edition", into: folder, hasPatches: true)
        try installMetadata(from: bundled, id: "a-edition", into: folder, hasPatches: true)
        let withBundle = PackLibrary(bundled: bundled, storage: PackStorage(directory: folder))
        #expect(withBundle.guildPatchArtwork(scientificName: Self.goose, setID: nil).setID == "us-ca-la")
        let downloadsOnly = PackLibrary(bundled: nil, storage: PackStorage(directory: folder))
        #expect(downloadsOnly.guildPatchArtwork(scientificName: Self.goose, setID: nil).setID == "a-edition")
    }

    @Test("without any local painting the original edition and blank remain, preserving the CDN fallback")
    func noPainting() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = PackLibrary(bundled: nil, storage: PackStorage(directory: folder))
        for edition in [nil, "us-ca-sd"] as [String?] {
            let artwork = library.guildPatchArtwork(scientificName: Self.goose, setID: edition)
            #expect(artwork.setID == edition)
            #expect(artwork.state == .tagged)
            #expect(artwork.note == nil)
        }
        let withBundle = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: folder))
        #expect(withBundle.guildPatchArtwork(scientificName: "Nonesuch nonesuch", setID: "us-ca-la").state == .tagged)
    }

    private func temporaryFolder() -> URL {
        URL.temporaryDirectory.appending(path: "GuildPatchArtworkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Only metadata is needed for lookup tests: no decoding, fake image files, or changes to the shipped pack.
    private func installMetadata(from source: SpeciesPack, id: String, into root: URL, hasPatches: Bool) throws {
        let folder = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appending(path: "pack.sqlite")
        try FileManager.default.copyItem(at: source.directory.appending(path: "pack.sqlite"), to: database)
        var connection: OpaquePointer?
        try #require(sqlite3_open(database.path(percentEncoded: false), &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        // IDs are fixed test strings, never user input.
        try #require(sqlite3_exec(connection, "UPDATE pack SET id = '\(id)'", nil, nil, nil) == SQLITE_OK)
        if !hasPatches { try #require(sqlite3_exec(connection, "DELETE FROM patch", nil, nil, nil) == SQLITE_OK) }
        let descriptor = PackDescriptor(id: id, name: id, version: source.info.version, url: URL(string: "https://example.invalid/pack.zip")!, sha256: "", byteCount: 1)
        try JSONEncoder().encode(descriptor).write(to: folder.appending(path: "installed.json"))
    }
}
