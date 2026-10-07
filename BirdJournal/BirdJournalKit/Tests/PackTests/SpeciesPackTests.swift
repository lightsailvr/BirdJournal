import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import Pack

/// The bundled Los Angeles pack as `scripts/download-pack.sh` fetched it (issue #12: about 150 species with photos
/// carrying observer, license and source URL, and Wikipedia-derived descriptions, offline; issue #41: a song and/or
/// call clip per species with its recordist, license and recording page).
@Suite("SpeciesPack")
struct SpeciesPackTests {
    static let allowedLicenses: Set<String> = ["CC0", "CC BY", "CC BY-NC"]

    @Test("the bundled pack opens with about 150 species in the definition's order")
    func bundledPack() throws {
        let pack = try SpeciesPack.bundled()
        #expect(pack.info.id == PackIndex.bundledPackID)
        #expect(pack.info.schemaVersion == SpeciesPack.schemaVersion)
        #expect((140...170).contains(pack.species.count), "\(pack.species.count) species")
        #expect(pack.species.first?.scientificName == "Buteo jamaicensis")
        #expect(pack.species(scientificName: "Calypte anna")?.commonName == "Anna's Hummingbird")
        #expect(pack.species(scientificName: "Nope nope") == nil)
    }

    @Test("every species has a description: field marks for the lens, a summary for the phone, and its Wikipedia revision")
    func speciesAreDescribed() throws {
        let pack = try SpeciesPack.bundled()
        for species in pack.species {
            #expect(species.isDescribed, "\(species.commonName) has no description")
            #expect(!(species.fieldMarks ?? "").isEmpty, "\(species.commonName) has no field marks")
            #expect((species.fieldMarks ?? "").split(separator: " ").count <= 40, "\(species.commonName): field marks over the lens budget")
            #expect(!(species.fieldMarks ?? "").hasSuffix("…"), "\(species.commonName): field marks cut mid-phrase (issue #32)")
            #expect(!(species.summary ?? "").isEmpty, "\(species.commonName) has no summary")
            if let source = species.descriptionSource {
                #expect(source.host() == "en.wikipedia.org" && source.query()?.contains("oldid=") == true, "\(species.commonName): \(source)")
                #expect(pack.info.licenseText.contains(source.absoluteString), "\(species.commonName)'s text credit is missing from LICENSE")
            }
        }
        let sized = pack.species.filter { !($0.size ?? "").isEmpty }.count
        let placed = pack.species.filter { !($0.habitat ?? "").isEmpty }.count
        #expect(sized * 10 >= pack.species.count * 8, "only \(sized) of \(pack.species.count) species have a size")
        #expect(placed * 10 >= pack.species.count * 9, "only \(placed) of \(pack.species.count) species have a habitat")
    }

    @Test("every species has one to five photos, best first, with full attribution; at least three unless logged as a gap")
    func photosCarryAttribution() throws {
        let pack = try SpeciesPack.bundled()
        let gaps = try Self.gaps(in: pack, key: "photos")
        for species in pack.species {
            #expect((1...5).contains(species.photos.count), "\(species.commonName) has \(species.photos.count) photos")
            #expect(species.photos.count >= 3 || gaps.contains(species.id), "\(species.commonName) has \(species.photos.count) photos and is not a logged gap")
            #expect(species.photos.map(\.rank) == Array(0..<species.photos.count))
            for photo in species.photos {
                #expect(!photo.observer.isEmpty)
                #expect(Self.allowedLicenses.contains(photo.license), "\(photo.id) is \(photo.license)")
                #expect(photo.sourceURL.host() == "www.inaturalist.org")
                #expect(photo.creditLine.contains(photo.observer))
                #expect(photo.shortCredit.hasPrefix("Photo: "))
                #expect(photo.licenseURL?.host() == "creativecommons.org", "\(photo.id) has no license link")
                #expect(pack.photo(id: photo.id) == photo)
            }
        }
        #expect(pack.photos.count == pack.species.reduce(0) { $0 + $1.photos.count })
    }

    @Test("lens crops are 552 × 368 pixels and phone crops at most 1200 pixels, on disk")
    func imagesExist() throws {
        let pack = try SpeciesPack.bundled()
        for photo in pack.photos {
            let lens = try #require(Self.pixelSize(of: pack.lensImageURL(for: photo)), "missing \(photo.lensFile)")
            #expect(lens == CGSize(width: 552, height: 368))
            let phone = try #require(Self.pixelSize(of: pack.phoneImageURL(for: photo)), "missing \(photo.phoneFile)")
            #expect(max(phone.width, phone.height) <= 1200)
            #expect(max(phone.width, phone.height) >= 552, "\(photo.phoneFile) is smaller than the lens crop")
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

    @Test("every species has a song and/or call clip or is a logged sound gap; no clip is ND, each is fully credited and on disk")
    func soundsCarryAttribution() throws {
        let pack = try SpeciesPack.bundled()
        let gaps = try Self.gaps(in: pack, key: "sounds")
        for species in pack.species {
            #expect(!species.sounds.isEmpty || gaps.contains(species.id), "\(species.commonName) has no sound and is not a logged gap")
            #expect(species.sounds.count <= 2, "\(species.commonName) has \(species.sounds.count) sounds")
            #expect(Set(species.sounds.map(\.kind)).count == species.sounds.count, "\(species.commonName) has two clips of one kind")
            #expect(species.sounds.map(\.rank) == Array(0..<species.sounds.count))
            for sound in species.sounds {
                #expect(!sound.recordist.isEmpty)
                #expect(!sound.license.contains("ND"), "\(sound.id) is \(sound.license)")
                #expect(sound.licenseURL?.host() == "creativecommons.org", "\(sound.id) has no license link")
                #expect(["xeno-canto.org", "www.inaturalist.org"].contains(sound.sourceURL.host() ?? ""), "\(sound.id): \(sound.sourceURL)")
                #expect(sound.creditLine.contains(sound.recordist) && sound.creditLine.contains(sound.license))
                #expect(sound.shortCredit.hasPrefix("Sound: "))
                #expect(pack.info.licenseText.contains(sound.creditLine), "\(sound.id)'s credit is missing from LICENSE")
                #expect(sound.duration > .seconds(1) && sound.duration <= .milliseconds(8_200), "\(sound.id) lasts \(sound.duration)")
                let file = try AVAudioFile(forReading: pack.soundURL(for: sound))
                #expect(file.length > 0, "\(sound.file) does not decode")
            }
        }
        #expect(pack.sounds.count * 10 >= pack.species.count * 9, "only \(pack.sounds.count) sounds for \(pack.species.count) species")
    }

    @Test("a folder without pack.sqlite is reported")
    func missingDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: PackError.missingDatabase(folder.appending(path: "pack.sqlite").path(percentEncoded: false))) {
            try SpeciesPack.open(directory: folder)
        }
    }

    @Test("an unknown bundled pack id is reported")
    func missingBundledPack() {
        #expect(throws: PackError.missingBundledPack("nowhere")) {
            try SpeciesPack.bundled(id: "nowhere")
        }
    }

    /// The species ids the builder logged under `key` in `report.json`'s "gaps": "photos" (fewer than three) or
    /// "sounds" (no clip).
    private static func gaps(in pack: SpeciesPack, key: String) throws -> Set<String> {
        let data = try Data(contentsOf: pack.directory.appending(path: "report.json"))
        let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let gaps = report?["gaps"] as? [String: [String]]
        return Set(gaps?[key] ?? [])
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
