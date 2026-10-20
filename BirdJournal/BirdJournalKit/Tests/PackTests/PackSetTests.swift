import Foundation
import Testing
@testable import Pack

/// Sets (issue #54): schema-4 packs carry their set definition, the reader still opens schemas 2 and 3, the index
/// carries every pack's set so a set works before its pack is downloaded, and the bundled Los Angeles pack places
/// every one of its species in its set.
@Suite("PackSet")
@MainActor
struct PackSetTests {
    static func install(_ resource: String, root: URL) throws -> SpeciesPack {
        let zip = try #require(Bundle.module.url(forResource: resource, withExtension: "zip", subdirectory: "Fixtures"), "Fixtures/\(resource).zip")
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        return try storage.install(zip: zip, as: Fixtures.descriptor(for: zip, version: 1)).pack
    }

    @Test("the reader opens schemas 2, 3 and 4; only schema 4 has a set")
    func opensSchemasTwoToFour() throws {
        for (resource, schema) in [("test-pack-schema2", 2), ("test-pack-schema3", 3), ("test-pack", 4)] {
            let root = try Fixtures.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let pack = try Self.install(resource, root: root)
            #expect(pack.info.schemaVersion == schema, "\(resource)")
            #expect(pack.species.count == 2, "\(resource)")
            #expect((pack.set != nil) == (schema >= 4), "\(resource)")
        }
        #expect(SpeciesPack.supportedSchemaVersions == 2...4)
    }

    @Test("a schema-4 pack's set has its edition, its regions and its species in taxonomic order")
    func schemaFourSet() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try #require(try Self.install("test-pack", root: root).set)

        #expect(set.id == "test-pack" && set.name == "Test Pack")
        #expect(set.edition.name == "Test edition" && !set.edition.theme.isEmpty)
        #expect(set.taxonomy == "IOC World Bird List 15.1")
        #expect(set.species.map(\.scientificName) == ["Calypte anna", "Sayornis nigricans"], "hummingbirds before tyrant flycatchers")
        #expect(set.species.first?.commonName == "Anna's Hummingbird")
        let region = try #require(set.regions.first)
        #expect(region.name == "Testland" && region.polygons.count == 1 && region.polygons[0][0].count == 5)
    }

    @Test("every species in the bundled Los Angeles pack has a set position")
    func bundledPackSet() throws {
        let pack = try SpeciesPack.bundled()
        #expect(pack.info.schemaVersion == 4)
        let set = try #require(pack.set, "the bundled pack has no set")
        #expect(set.id == PackIndex.bundledPackID && set.name == pack.info.name)
        #expect(set.edition.name.hasSuffix("edition"))
        let positions = Dictionary(uniqueKeysWithValues: set.species.enumerated().map { ($1.scientificName, $0 + 1) })
        #expect(positions.count == set.species.count, "a species is listed twice")
        for species in pack.species {
            #expect(positions[species.scientificName] != nil, "\(species.commonName) has no set position")
            #expect(set.species.first { $0.scientificName == species.scientificName }?.commonName == species.commonName)
        }
        #expect(set.species.count == pack.species.count)
        #expect(set.regions.map(\.name) == ["Los Angeles County"])
        #expect(set.regions.allSatisfy { region in region.polygons.allSatisfy { $0.allSatisfy { ring in ring.count >= 4 && ring.first == ring.last } } })
    }

    @Test("the index carries each pack's set, and a set this build can't read costs only the set")
    func indexCarriesSets() throws {
        let json = """
            {"packs": [
              {"id": "a", "name": "A", "version": 1, "url": "https://example.com/a.zip", "sha256": "ab", "byteCount": 1, "schemaVersion": 4,
               "set": {"id": "a", "name": "A", "edition": {"name": "A edition", "theme": "light"}, "taxonomy": "IOC World Bird List 15.1",
                       "regions": [{"name": "A County", "source": "census", "polygons": [[[[0, 0], [1, 0], [1, 1], [0, 0]]]]}],
                       "species": [{"scientificName": "Calypte anna", "commonName": "Anna's Hummingbird"}]}},
              {"id": "b", "name": "B", "version": 1, "url": "https://example.com/b.zip", "sha256": "ab", "byteCount": 1, "schemaVersion": 5,
               "set": {"id": "b", "shape": "something newer"}},
              {"id": "c", "name": "C", "version": 1, "url": "https://example.com/c.zip", "sha256": "ab", "byteCount": 1}
            ]}
            """
        let index = try PackIndex.decode(from: Data(json.utf8))
        #expect(index.packs.map(\.id) == ["a", "b", "c"])
        #expect(index.packs[0].set?.species.map(\.scientificName) == ["Calypte anna"])
        #expect(index.packs[0].set?.regions.first?.polygons.first?.first?.count == 4)
        #expect(index.packs[1].set == nil && index.packs[1].schemaVersion == 5)
        #expect(index.packs[2].set == nil)
    }

    @Test("the library knows the sets of its packs and of the index's packs not on the phone, one per pack")
    func librarySets() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexSet = PackSet(
            id: "us-ca-sd", name: "San Diego", edition: .init(name: "Coastal edition", theme: "coast"), taxonomy: "IOC World Bird List 15.1",
            regions: [], species: [.init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird")]
        )
        let staleBundledSet = PackSet(
            id: PackIndex.bundledPackID, name: "Los Angeles", edition: .init(name: "Old edition", theme: "x"), taxonomy: "x", regions: [], species: []
        )
        let zip = try Fixtures.testPackZip()
        let index = PackIndex(packs: [
            PackDescriptor(id: PackIndex.bundledPackID, name: "Los Angeles", version: 1, url: zip, sha256: "x", byteCount: 1, schemaVersion: 4, set: staleBundledSet),
            PackDescriptor(id: "us-ca-sd", name: "San Diego", version: 1, url: zip, sha256: "x", byteCount: 1, schemaVersion: 4, set: indexSet),
        ])
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(index).write(to: indexURL)
        let library = PackLibrary(bundled: try SpeciesPack.bundled(), storage: PackStorage(directory: root.appending(path: "Packs")), indexURL: indexURL, availableCapacity: { nil })

        #expect(library.sets.map(\.id) == [PackIndex.bundledPackID], "before the index, the bundled pack's own set")
        await library.refreshIndex()
        #expect(library.sets.map(\.id) == [PackIndex.bundledPackID, "us-ca-sd"])
        #expect(library.sets.first?.edition.name != "Old edition", "the pack on the phone wins over the index's copy")
        #expect(library.sets.last == indexSet)
    }

    @Test("the last good index is kept, so the sets it carries survive a relaunch with no network")
    func indexKeptForOfflineLaunch() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = PackSet(
            id: "us-ca-sd", name: "San Diego", edition: .init(name: "Coastal edition", theme: "coast"), taxonomy: "IOC World Bird List 15.1",
            regions: [], species: [.init(scientificName: "Calypte anna", commonName: "Anna's Hummingbird")]
        )
        let zip = try Fixtures.testPackZip()
        let indexURL = root.appending(path: "index.json")
        try JSONEncoder().encode(PackIndex(packs: [PackDescriptor(id: "us-ca-sd", name: "San Diego", version: 1, url: zip, sha256: "x", byteCount: 1, schemaVersion: 4, set: set)]))
            .write(to: indexURL)
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        let online = PackLibrary(bundled: nil, storage: storage, indexURL: indexURL, availableCapacity: { nil })
        await online.refreshIndex()
        #expect(online.sets.map(\.id) == ["us-ca-sd"])

        let offline = PackLibrary(bundled: nil, storage: storage, indexURL: root.appending(path: "missing.json"), availableCapacity: { nil })
        #expect(offline.sets == [set], "known at launch, before any fetch")
        await offline.refreshIndex()
        #expect(offline.indexError != nil)
        #expect(offline.sets == [set], "a failed fetch keeps the last good index")
        #expect(storage.installed().isEmpty, "the kept index is not taken for a pack")
    }
}
