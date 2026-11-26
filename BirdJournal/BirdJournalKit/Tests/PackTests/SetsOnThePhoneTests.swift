import Foundation
import Testing
@testable import Pack

/// Issue #207 (of #206): only the sets whose pack is on the phone take sightings, while the phone still knows every set
/// (for the Atlas, a place's painting and a download's offer); and a species two packs describe is read from the
/// sighting's own set's pack, then a download, then the bundled pack.
@Suite("Sets on the phone")
@MainActor
struct PackSetsOnThePhoneTests {
    /// A set only the index describes: nothing of it is on the phone.
    static let indexOnly = PackSet(
        id: "us-test-elsewhere", name: "Elsewhere", edition: .init(name: "Elsewhere edition", theme: "x"), taxonomy: "IOC World Bird List 15.1",
        regions: [], species: [.init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird")]
    )

    /// The bundled pack, the sets that shipped with the app, and an index offering the fixture pack and listing `indexOnly`.
    static func library(root: URL, bundled: Bool = true) throws -> PackLibrary {
        let zip = try Fixtures.testPackZip()
        let index = PackIndex(packs: [
            try Fixtures.descriptor(for: zip, version: 1),
            PackDescriptor(id: indexOnly.id, name: indexOnly.name, version: 1, url: zip, sha256: "x", byteCount: 1, schemaVersion: 4, set: indexOnly),
        ])
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(index).write(to: indexURL)
        return PackLibrary(
            bundled: bundled ? try SpeciesPack.bundled() : nil, storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL, availableCapacity: { nil }
        )
    }

    @Test("the sets that take sightings are those of the packs on the phone; the known sets still include the index's and the ones shipped with the app")
    func setsThatTakeSightings() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.library(root: root)
        let bundledID = try #require(library.bundled).info.id
        let shipped = Set(BundledCovers.shipped.sets.map(\.id))
        #expect(shipped.count > 1, "sets shipped with the app besides the bundled pack's")

        await library.refreshIndex()
        #expect(library.indexError == nil)

        #expect(library.setsTakingSightings.map(\.id) == [bundledID], "only the bundled pack is on the phone")
        let known = Set(library.sets.map(\.id))
        #expect(known == shipped.union([bundledID, "us-test-elsewhere"]), "a set is known before its pack is downloaded")
        #expect(library.set(id: "us-test-elsewhere") == Self.indexOnly)

        let descriptor = try #require(library.available.first { $0.id == "test-pack" })
        await library.download(descriptor)

        #expect(library.setsTakingSightings.map(\.id) == [bundledID, "test-pack"], "a download's set takes sightings from then on")
        #expect(library.setsTakingSightings.last == library.pack(id: "test-pack")?.set, "the definition its pack carries")
        #expect(Set(library.sets.map(\.id)) == known.union(["test-pack"]))
        #expect(library.sets.count == known.count + 1, "each set once")

        try library.remove(id: "test-pack")

        #expect(library.setsTakingSightings.map(\.id) == [bundledID], "a deleted download's set takes none")
        #expect(Set(library.sets.map(\.id)) == known, "the Atlas still lists what it knew")
    }

    @Test("with no pack on the phone no set takes a sighting, though the phone knows sets")
    func noPackNoPlacement() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Self.library(root: root, bundled: false)
        await library.refreshIndex()

        #expect(library.setsTakingSightings.isEmpty)
        #expect(library.sets.contains(Self.indexOnly))
        #expect(Set(library.sets.map(\.id)).isSuperset(of: BundledCovers.shipped.sets.map(\.id)))
    }
}
