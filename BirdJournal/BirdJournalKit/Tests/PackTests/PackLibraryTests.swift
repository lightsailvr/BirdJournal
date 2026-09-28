import Foundation
import Testing
@testable import Pack

/// The packs the app reads (issue #13): the bundled pack first, then every download, looked up as one; the index
/// fetched from its URL; a download that verifies, installs and shows up; a removal that takes its species with it.
@Suite("PackLibrary")
@MainActor
struct PackLibraryTests {
    @Test("the bundled pack is there before any download and its species resolve")
    func bundledFirst() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root)

        #expect(library.packs.map(\.info.id) == [PackIndex.bundledPackID])
        #expect(library.species(scientificName: "Calypte anna")?.species.commonName == "Anna's Hummingbird")
        #expect(library.species(scientificName: "Calypte anna")?.pack.info.id == PackIndex.bundledPackID)
        #expect(library.index == nil && library.available.isEmpty)
    }

    @Test("the index lists the packs not bundled or installed, and a download installs one that then resolves")
    func downloadsFromIndex() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root)

        await library.refreshIndex()

        #expect(library.indexError == nil)
        #expect(library.available.map(\.id) == ["test-pack"], "the bundled pack is in the index but not offered")
        let descriptor = try #require(library.available.first)
        #expect(library.status(of: descriptor) == .notInstalled)

        await library.download(descriptor)

        #expect(library.status(of: descriptor) == .installed(version: 1))
        #expect(library.packs.map(\.info.id) == [PackIndex.bundledPackID, "test-pack"])
        #expect(library.available.isEmpty)
        // Black Phoebe is in both packs: the bundled one wins.
        #expect(library.species(scientificName: "Sayornis nigricans")?.pack.info.id == PackIndex.bundledPackID)
        let phoebe = try #require(library.pack(id: "test-pack")?.species(scientificName: "Sayornis nigricans"))
        #expect(library.photo(id: phoebe.photos[0].id)?.pack.info.id == "test-pack")
        #expect(library.storage.installed().map(\.descriptor.id) == ["test-pack"])

        // A fresh library on the same storage sees the install.
        let relaunched = try Fixtures.library(root: root)
        #expect(relaunched.packs.map(\.info.id) == [PackIndex.bundledPackID, "test-pack"])
    }

    @Test("a newer version in the index is offered as an update over an installed pack")
    func offersUpdate() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try Fixtures.testPackZip()
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        _ = try storage.install(zip: zip, as: try Fixtures.descriptor(for: zip, version: 1))
        let library = try Fixtures.library(root: root, indexVersion: 2)

        await library.refreshIndex()

        let descriptor = try #require(library.index?.packs.first { $0.id == "test-pack" })
        #expect(library.status(of: descriptor) == .updateAvailable(installed: 1, available: 2))
        #expect(library.available.isEmpty, "an installed pack is listed as installed, not as available")
    }

    @Test("a download whose checksum fails leaves the library as it was and reports it")
    func failedDownload() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root, sha256: String(repeating: "f", count: 64))
        await library.refreshIndex()
        let descriptor = try #require(library.available.first)

        await library.download(descriptor)

        guard case .failed(let message) = library.status(of: descriptor) else {
            Issue.record("expected a failed status, got \(library.status(of: descriptor))")
            return
        }
        #expect(message.contains("checksum") || message.contains("SHA"))
        #expect(library.packs.count == 1)
        #expect(library.storage.installed().isEmpty)
    }

    @Test("an unreachable index is reported, not fatal")
    func unreachableIndex() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PackLibrary(
            bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")),
            indexURL: root.appending(path: "missing.json")
        )

        await library.refreshIndex()

        #expect(library.index == nil)
        #expect(library.indexError != nil)
    }

    @Test("a newer version of the bundled pack in the index is offered, takes the bundled pack's place once downloaded, and deleting it goes back")
    func bundledUpdate() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // The fixture zip is a two-species pack under the bundled pack's id; the index lists it one version past
        // whatever the bundle holds.
        let newer = try #require(Bundle.module.url(forResource: "us-ca-la-v2", withExtension: "zip", subdirectory: "Fixtures"))
        let bundledVersion = try SpeciesPack.bundled().info.version
        let next = bundledVersion + 1
        let library = try Fixtures.library(root: root, bundledZip: newer, bundledVersion: next)
        let bundledCount = try #require(library.bundled).species.count
        #expect(bundledCount > 100)

        await library.refreshIndex()

        let descriptor = try #require(library.index?.descriptor(id: PackIndex.bundledPackID))
        #expect(library.status(of: descriptor) == .updateAvailable(installed: bundledVersion, available: next))
        #expect(library.available.map(\.id) == ["test-pack"], "the bundled pack's update is offered on its own row, not as a download")

        await library.download(descriptor)

        #expect(library.status(of: descriptor) == .installed(version: next))
        #expect(library.bundledUpdate?.descriptor.version == next)
        #expect(library.packs.first?.species.count == 2, "the downloaded version stands in for the bundled copy")
        #expect(library.packs.count == 1 && library.downloads.isEmpty)
        #expect(library.pack(id: PackIndex.bundledPackID)?.species.count == 2)

        try library.remove(id: PackIndex.bundledPackID)

        #expect(library.status(of: descriptor) == .updateAvailable(installed: bundledVersion, available: next))
        #expect(library.packs.first?.species.count == bundledCount, "back to the bundled copy")
        #expect(library.bundledUpdate == nil)
    }

    @Test("a zip that holds another pack than the index entry names installs nothing")
    func wrongPack() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try Fixtures.testPackZip()  // its pack id is test-pack
        let library = try Fixtures.library(root: root, bundledZip: zip, bundledVersion: 2)
        await library.refreshIndex()
        let descriptor = try #require(library.index?.descriptor(id: PackIndex.bundledPackID))

        await library.download(descriptor)

        #expect(library.status(of: descriptor) == .failed("The download holds the pack test-pack, not us-ca-la."))
        #expect(library.bundledUpdate == nil)
    }

    @Test("removing a downloaded pack deletes its files and its species")
    func removes() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root)
        await library.refreshIndex()
        let descriptor = try #require(library.available.first)
        await library.download(descriptor)
        let directory = try #require(library.pack(id: "test-pack")?.directory)

        try library.remove(id: "test-pack")

        #expect(library.packs.map(\.info.id) == [PackIndex.bundledPackID])
        #expect(library.pack(id: "test-pack") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(library.status(of: descriptor) == .notInstalled)
        #expect(library.available.map(\.id) == ["test-pack"], "back on offer")
    }
}

extension Fixtures {
    /// A library over the bundled pack, a temp storage folder and an index file listing the bundled pack and the
    /// fixture pack (served from a file URL).
    @MainActor
    static func library(
        root: URL, indexVersion: Int = 1, sha256: String? = nil, bundledZip: URL? = nil, bundledVersion: Int = 1,
        zip: URL? = nil, availableCapacity: (() -> Int64?)? = nil
    ) throws -> PackLibrary {
        let zip = try zip ?? testPackZip()
        var descriptor = try descriptor(for: zip, version: indexVersion)
        if let sha256 {
            descriptor = PackDescriptor(id: descriptor.id, name: descriptor.name, version: indexVersion, url: zip, sha256: sha256, byteCount: descriptor.byteCount)
        }
        let bundledZip = bundledZip ?? zip
        let bundled = PackDescriptor(id: PackIndex.bundledPackID, name: "Los Angeles", version: bundledVersion, url: bundledZip, sha256: try PackStorage.sha256(of: bundledZip), byteCount: 1)
        let index = PackIndex(packs: [bundled, descriptor])
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(index).write(to: indexURL)
        return PackLibrary(
            bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL,
            availableCapacity: availableCapacity ?? { nil }
        )
    }
}
