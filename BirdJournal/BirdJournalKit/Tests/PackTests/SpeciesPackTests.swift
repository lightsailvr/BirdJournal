import Foundation
import ImageIO
import Testing
@testable import Pack

/// The bundled Los Angeles pack as `scripts/build-pack.sh` wrote it (issue #8 acceptance: ten species, photos with
/// observer, license and source URL, offline).
@Suite("SpeciesPack")
struct SpeciesPackTests {
    static let allowedLicenses: Set<String> = ["CC0", "CC BY", "CC BY-NC"]

    @Test("the bundled pack opens with ten species in order")
    func bundledPack() throws {
        let pack = try SpeciesPack.bundled()
        #expect(pack.info.id == PackIndex.bundledPackID)
        #expect(pack.info.schemaVersion == SpeciesPack.schemaVersion)
        #expect(pack.species.count == 10)
        #expect(pack.species.first?.scientificName == "Sayornis nigricans")
        #expect(pack.species(scientificName: "Calypte anna")?.commonName == "Anna's Hummingbird")
        #expect(pack.species(scientificName: "Nope nope") == nil)
    }

    @Test("every species has three to five photos, best first, with full attribution")
    func photosCarryAttribution() throws {
        let pack = try SpeciesPack.bundled()
        for species in pack.species {
            #expect((3...5).contains(species.photos.count), "\(species.commonName) has \(species.photos.count) photos")
            #expect(species.photos.map(\.rank) == Array(0..<species.photos.count))
            for photo in species.photos {
                #expect(!photo.observer.isEmpty)
                #expect(Self.allowedLicenses.contains(photo.license), "\(photo.id) is \(photo.license)")
                #expect(photo.sourceURL.host() == "www.inaturalist.org")
                #expect(photo.creditLine.contains(photo.observer))
                #expect(photo.shortCredit.hasPrefix("Photo: "))
                #expect(pack.photo(id: photo.id) == photo)
            }
        }
        #expect(pack.photos.count == pack.species.reduce(0) { $0 + $1.photos.count })
    }

    @Test("lens crops are 260 pixels square and phone crops at most 1200 pixels, on disk")
    func imagesExist() throws {
        let pack = try SpeciesPack.bundled()
        for photo in pack.photos {
            let lens = try #require(Self.pixelSize(of: pack.lensImageURL(for: photo)), "missing \(photo.lensFile)")
            #expect(lens == CGSize(width: 260, height: 260))
            let phone = try #require(Self.pixelSize(of: pack.phoneImageURL(for: photo)), "missing \(photo.phoneFile)")
            #expect(max(phone.width, phone.height) <= 1200)
            #expect(max(phone.width, phone.height) > 260)
        }
    }

    @Test("the LICENSE text lists every credit")
    func licenseListsCredits() throws {
        let pack = try SpeciesPack.bundled()
        for photo in pack.photos {
            #expect(pack.info.licenseText.contains(photo.creditLine))
            #expect(pack.info.licenseText.contains(photo.sourceURL.absoluteString))
        }
        let onDisk = try String(contentsOf: pack.directory.appending(path: "LICENSE"), encoding: .utf8)
        #expect(onDisk == pack.info.licenseText)
    }

    @Test("a folder without pack.sqlite is reported")
    func missingDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: PackError.missingDatabase(folder.appending(path: "pack.sqlite").path())) {
            try SpeciesPack.open(directory: folder)
        }
    }

    @Test("an unknown bundled pack id is reported")
    func missingBundledPack() {
        #expect(throws: PackError.missingBundledPack("nowhere")) {
            try SpeciesPack.bundled(id: "nowhere")
        }
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
