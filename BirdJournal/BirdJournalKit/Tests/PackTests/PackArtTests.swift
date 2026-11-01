import Foundation
import ImageIO
import Testing
@testable import Pack

/// Pack art (issue #57): a schema-4 pack carries one reviewed painting per species (3:4 AVIF) with the photo it was
/// painted from, and the bundled Los Angeles pack has one for every species but its listed gaps, inside the app's
/// 200 MB budget for the pack.
@Suite("PackArt")
@MainActor
struct PackArtTests {
    /// The bundled pack's budget on disk: the app-size check of #12 (DECISIONS.md, "Species pack").
    static let budgetBytes = 200_000_000

    @Test("a species' pack art names its file, the photo it was painted from and the workflow; a gap has none")
    func fixtureArt() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack", root: root)

        let phoebe = try #require(pack.species(scientificName: "Sayornis nigricans"))
        let art = try #require(phoebe.packArt)
        #expect(art.file == "art/sayornis-nigricans.avif")
        #expect(art.sourcePhotoIDs == [1])
        #expect(art.workflowVersion == "pack-art@3 bird-isolate@1 prompts@8")
        #expect(Self.pixelSize(of: pack.artURL(for: art)) == CGSize(width: 864, height: 1152), "AVIF decodes on the phone")
        #expect(pack.sourcePhotos(of: art).map(\.inatPhotoID) == [1], "the provenance credits the photo")
        #expect(pack.species(scientificName: "Calypte anna")?.packArt == nil)
    }

    @Test("a card takes the pack art of its set's pack first, then of the first pack that has art for the species")
    func libraryArt() async throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Fixtures.library(root: root)
        await library.refreshIndex()
        await library.download(try #require(library.available.first))

        #expect(library.packArt(scientificName: "Sayornis nigricans", setID: "test-pack")?.pack.info.id == "test-pack")
        #expect(library.packArt(scientificName: "Sayornis nigricans", setID: nil)?.pack.info.id == PackIndex.bundledPackID)
        #expect(library.packArt(scientificName: "Calypte anna", setID: "test-pack")?.pack.info.id == PackIndex.bundledPackID, "the test pack's gap")
        #expect(library.packArt(scientificName: "Turdus merula", setID: nil) == nil)
    }

    @Test("a schema-3 pack has no pack art")
    func olderSchemas() throws {
        let root = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try PackSetTests.install("test-pack-schema3", root: root)
        #expect(pack.species.allSatisfy { $0.packArt == nil })
    }

    @Test("every Los Angeles species has pack art on disk, painted from one of its own photos, or is a listed gap")
    func bundledArt() throws {
        let pack = try SpeciesPack.bundled()
        let gaps = try Self.artGaps(in: pack)
        for species in pack.species {
            guard let art = species.packArt else {
                #expect(gaps.contains(species.id), "\(species.commonName) has no pack art and is not a listed gap")
                continue
            }
            #expect(!gaps.contains(species.id), "\(species.commonName) is a listed gap but has art")
            #expect(Self.pixelSize(of: pack.artURL(for: art)) == CGSize(width: 864, height: 1152), "\(art.file)")
            let photos = pack.sourcePhotos(of: art)
            #expect(photos.count == art.sourcePhotoIDs.count, "\(species.commonName) was painted from a photo the pack doesn't have")
            #expect(photos.allSatisfy { $0.speciesID == species.id })
            for photo in photos {
                #expect(pack.info.licenseText.contains("\(species.commonName): painted from photo \(photo.inatPhotoID)"), "\(species.commonName)'s art credit")
            }
        }
        #expect(pack.species.filter { $0.packArt != nil }.count + gaps.count == pack.species.count)
    }

    @Test("the bundled pack, art and all, stays inside the 200 MB budget")
    func bundledSize() throws {
        let pack = try SpeciesPack.bundled()
        let bytes = try Self.bytes(in: pack.directory)
        let art = try Self.bytes(in: pack.directory.appending(path: "art"))
        print("bundled pack \(pack.info.id) v\(pack.info.version): \(bytes / 1_000_000) MB on disk, \(art / 1_000_000) MB of it pack art, budget \(Self.budgetBytes / 1_000_000) MB")
        #expect(bytes <= Self.budgetBytes, "\(bytes) bytes")
    }

    private static func artGaps(in pack: SpeciesPack) throws -> Set<String> {
        let data = try Data(contentsOf: pack.directory.appending(path: "report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set((report?["gaps"] as? [String: [String]])?["art"] ?? [])
    }

    private static func bytes(in folder: URL) throws -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
