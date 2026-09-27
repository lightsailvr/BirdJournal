import Foundation
import Testing
@testable import Pack

/// Downloaded packs on disk (issue #13): a zip is checked against its descriptor's SHA-256, unpacked into its own folder
/// beside the record of what was installed, listed on the next launch, and removed with its files.
@Suite("PackStorage")
struct PackStorageTests {
    @Test("installs a verified zip, lists it, and replaces an older install of the same pack")
    func installsAndLists() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let zip = try Fixtures.testPackZip()
        let descriptor = try Fixtures.descriptor(for: zip, version: 1)
        #expect(storage.installed().isEmpty)

        let installed = try storage.install(zip: zip, as: descriptor)

        #expect(installed.descriptor == descriptor)
        #expect(installed.pack.info.id == "test-pack")
        #expect(installed.pack.species.count == 2)
        #expect(installed.pack.directory == storage.url(for: "test-pack"))
        #expect(FileManager.default.fileExists(atPath: installed.pack.lensImageURL(for: installed.pack.photos[0]).path(percentEncoded: false)))
        #expect(storage.installed() == [installed])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Packs/test-pack.unpacking").path(percentEncoded: false)))

        let newer = try Fixtures.descriptor(for: zip, version: 2)
        let updated = try storage.install(zip: zip, as: newer)
        #expect(updated.descriptor.version == 2)
        #expect(storage.installed().map(\.descriptor.version) == [2])
    }

    @Test("a zip whose SHA-256 does not match its descriptor installs nothing")
    func checksumMismatch() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let zip = try Fixtures.testPackZip()
        let wrong = String(repeating: "0", count: 64)
        let descriptor = PackDescriptor(id: "test-pack", name: "Test Pack", version: 1, url: zip, sha256: wrong, byteCount: 1)

        #expect(throws: PackInstallError.checksumMismatch(expected: wrong, actual: try PackStorage.sha256(of: zip))) {
            try storage.install(zip: zip, as: descriptor)
        }
        #expect(storage.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.url(for: "test-pack").path(percentEncoded: false)))
    }

    @Test("a zip that is not a pack installs nothing")
    func notAPack() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let zip = root.appending(path: "empty.zip")
        try Fixtures.storedZip(entries: [("readme.txt", Data("not a pack".utf8))]).write(to: zip)
        let descriptor = try Fixtures.descriptor(for: zip, version: 1, id: "empty")

        #expect(throws: PackError.missingDatabase(storage.directory.appending(path: "empty.unpacking/pack.sqlite").path(percentEncoded: false))) {
            try storage.install(zip: zip, as: descriptor)
        }
        #expect(storage.installed().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.directory.path(percentEncoded: false)).isEmpty)
    }

    @Test("removing a pack deletes its folder and it is no longer listed")
    func removes() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let zip = try Fixtures.testPackZip()
        let installed = try storage.install(zip: zip, as: try Fixtures.descriptor(for: zip, version: 1))

        try storage.remove(id: "test-pack")

        #expect(storage.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.pack.directory.path(percentEncoded: false)))
        try storage.remove(id: "test-pack")  // removing what is not there is not an error
    }

    @Test("a staging folder left by a crash is not listed and is cleaned up; the record is only ever under the final name")
    func staleStaging() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let zip = try Fixtures.testPackZip()
        let stale = storage.directory.appending(path: "test-pack.unpacking")
        try ZipArchive.extract(zip, into: stale)
        try JSONEncoder().encode(try Fixtures.descriptor(for: zip, version: 1)).write(to: stale.appending(path: "installed.json"))

        #expect(storage.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
    }

    @Test("a storage folder with a space in its path, like Application Support, works")
    func spaceInPath() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PackStorage(directory: root.appending(path: "Application Support/Packs", directoryHint: .isDirectory))
        let zip = try Fixtures.testPackZip()

        let installed = try storage.install(zip: zip, as: try Fixtures.descriptor(for: zip, version: 1))

        #expect(installed.pack.species.count == 2)
        #expect(storage.installed().count == 1)
        #expect(FileManager.default.fileExists(atPath: installed.pack.lensImageURL(for: installed.pack.photos[0]).path(percentEncoded: false)))
    }

    @Test("the SHA-256 of a file matches the system's")
    func sha256() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "abc.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try PackStorage.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

extension Fixtures {
    /// A descriptor for a zip on disk, with its real SHA-256 and size.
    static func descriptor(for zip: URL, version: Int, id: String = "test-pack") throws -> PackDescriptor {
        let bytes = try FileManager.default.attributesOfItem(atPath: zip.path(percentEncoded: false))[.size] as? Int ?? 0
        return PackDescriptor(id: id, name: "Test Pack", version: version, url: zip, sha256: try PackStorage.sha256(of: zip), byteCount: bytes)
    }
}
