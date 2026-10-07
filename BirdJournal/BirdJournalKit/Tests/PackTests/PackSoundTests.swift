import AVFoundation
import Foundation
import Testing
@testable import Pack

/// Reference sounds in a pack (issue #41): the `sound` table read into `PackSound`s, the clips on disk and decodable,
/// full attribution on every one, a schema-2 pack still opening without sounds, and a pack of a newer schema refused
/// before it is downloaded.
@Suite("PackSound")
struct PackSoundTests {
    @Test("a schema-3 pack's sounds are read with their credits, and the clip decodes")
    func readsSounds() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try Self.install(Fixtures.testPackZip(), root: root)

        #expect(pack.info.schemaVersion == 3)
        let phoebe = try #require(pack.species(scientificName: "Sayornis nigricans"))
        let song = try #require(phoebe.sounds.first)
        #expect(phoebe.sounds.count == 1 && pack.sounds(for: phoebe) == phoebe.sounds)
        #expect(song.id == "xc-1" && song.kind == .song && song.rank == 0 && song.speciesID == phoebe.id)
        #expect(song.recordist == "Jane Recordist" && song.license == "CC BY-SA 4.0" && song.quality == "A")
        #expect(song.creditLine == "Jane Recordist, XC1, https://xeno-canto.org/1 (CC BY-SA 4.0)")
        #expect(song.shortCredit == "Sound: Jane Recordist, XC1")
        #expect(song.sourceURL == URL(string: "https://xeno-canto.org/1"))
        #expect(song.licenseURL == URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"))
        #expect((Duration.milliseconds(1_850)...Duration.milliseconds(2_150)).contains(song.duration), "\(song.duration)")
        #expect(pack.species(scientificName: "Calypte anna")?.sounds.isEmpty == true)
        #expect(pack.sounds == [song])
        #expect(pack.info.licenseText.contains(song.creditLine))

        let file = try AVAudioFile(forReading: pack.soundURL(for: song))
        #expect(file.fileFormat.channelCount == 1 && file.fileFormat.sampleRate == 48_000)
        #expect(file.length > 0)
    }

    @Test("a schema-2 pack downloaded before sounds existed still opens, without sounds")
    func schemaTwoStillOpens() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try #require(Bundle.module.url(forResource: "test-pack-schema2", withExtension: "zip", subdirectory: "Fixtures"))
        let pack = try Self.install(zip, root: root)

        #expect(pack.info.schemaVersion == 2)
        #expect(pack.species.count == 2 && pack.sounds.isEmpty)
    }

    @Test("license deeds follow the version; ND and unknown licenses have none")
    func licenseDeeds() {
        #expect(Self.sound(license: "CC BY-NC-SA 3.0").licenseURL == URL(string: "https://creativecommons.org/licenses/by-nc-sa/3.0/"))
        #expect(Self.sound(license: "CC0").licenseURL == URL(string: "https://creativecommons.org/publicdomain/zero/1.0/"))
        #expect(Self.sound(license: "CC BY-NC-ND 4.0").licenseURL == nil)
        #expect(Self.sound(license: "All rights reserved").licenseURL == nil)
    }

    @Test("the index's schema decides whether this build can open a pack; a missing schema means 2")
    func indexSchema() throws {
        let json = Data("""
            {"packs": [
              {"id": "a", "name": "A", "version": 1, "url": "https://example.com/a.zip", "sha256": "ab", "byteCount": 1, "schemaVersion": 3, "soundCount": 300},
              {"id": "b", "name": "B", "version": 1, "url": "https://example.com/b.zip", "sha256": "ab", "byteCount": 1},
              {"id": "c", "name": "C", "version": 1, "url": "https://example.com/c.zip", "sha256": "ab", "byteCount": 1, "schemaVersion": 4}
            ]}
            """.utf8)
        let index = try PackIndex.decode(from: json)
        #expect(index.packs.map(\.isSupported) == [true, true, false])
        #expect(index.packs[0].soundCount == 300 && index.packs[1].soundCount == nil && index.packs[1].schemaVersion == nil)
    }

    @Test("a pack of a newer schema is listed as needing a newer app and is not downloaded")
    @MainActor
    func newerSchemaIsNotDownloaded() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PackLibrary(bundled: nil, storage: PackStorage(directory: root.appending(path: "Packs")))
        let descriptor = PackDescriptor(
            id: "future", name: "Future", version: 1, url: URL(string: "https://example.com/future.zip")!, sha256: "", byteCount: 1,
            schemaVersion: SpeciesPack.schemaVersion + 1
        )

        #expect(library.status(of: descriptor) == .needsNewerApp)
        library.startDownload(descriptor)
        #expect(library.status(of: descriptor) == .needsNewerApp, "no download started")
    }

    private static func install(_ zip: URL, root: URL) throws -> SpeciesPack {
        let storage = PackStorage(directory: root.appending(path: "Packs"))
        return try storage.install(zip: zip, as: try Fixtures.descriptor(for: zip, version: 1)).pack
    }

    private static func sound(license: String) -> PackSound {
        PackSound(
            id: "xc-1", speciesID: "s", rank: 0, kind: .call, file: "sounds/xc-1.m4a", duration: .seconds(8), recordist: "R", license: license,
            creditLine: "", shortCredit: "", sourceURL: URL(string: "https://xeno-canto.org/1")!, quality: nil
        )
    }
}
