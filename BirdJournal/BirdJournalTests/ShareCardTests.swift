import Album
import Foundation
import ImageIO
import Pack
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #66: the system share sends the card face in place of the postcard. The exported image carries its pixels and
// nothing else (no Exif, GPS or TIFF metadata, checked with ImageIO as the postcard was), even when the art's own file
// carries a place, a time and a device; a pack photo whose license doesn't allow a share leaves the face.
@Suite("Share card")
struct ShareCardTests {
    static let sighting = SharePolicyTests.sighting

    @Test("the card face exports as a PNG with no Exif, GPS or TIFF metadata, whatever the art's file knew")
    @MainActor
    func exportHasNoMetadata() throws {
        // Art whose file carries a GPS fix, an Exif date and lens, and a TIFF make and model.
        let tagged = try ArtPhotoTests.withMetadata(ArtPhotoTests.fixture())
        #expect(try ArtPhotoTests.properties(tagged)[kCGImagePropertyGPSDictionary] != nil, "the source does carry GPS")
        let art = try #require(UIImage(data: tagged))
        let face = CardFront(
            sighting: Self.sighting, isLegendary: true, placement: nil, place: "Los Angeles",
            art: .packArt(URL(fileURLWithPath: "/nonexistent.avif"), credit: nil), artImage: art
        )
        .environment(PackLibrary.forApp())
        let export = try #require(CardExport.render(face, scale: 2))

        let source = try #require(CGImageSourceCreateWithData(export.png as CFData, nil))
        #expect(CGImageSourceGetType(source) == UTType.png.identifier as CFString)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        #expect(properties[kCGImagePropertyIPTCDictionary] == nil)
        // ImageIO records the pixel size (and colour space) under Exif; nothing that dates, places or attributes the
        // picture to a device may be there.
        let exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let telling: [CFString] = [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifUserComment,
            kCGImagePropertyExifMakerNote, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake, kCGImagePropertyExifSubjectLocation,
        ]
        #expect(telling.allSatisfy { exif[$0] == nil }, "Exif keys: \(exif.keys.map { $0 as String }.sorted())")
        #expect(properties[kCGImagePropertyOrientation] == nil)
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) == 720)
    }

    @Test("a pack photo stays on the face only when its license allows a share")
    func referencePhotoLicense() {
        let url = URL(fileURLWithPath: "/phone/1.jpg")
        let photo: CardText.Art = .referencePhoto(url, credit: "© A. Birder")
        for (license, shown) in [("CC BY", true), ("CC BY-SA", true), ("All rights reserved", false)] {
            var choices = SharePolicy.Choices()
            choices.useSnapshot = false
            let content = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: SharePolicyTests.photo(license: license), area: nil, choices: choices)
            #expect(ShareCardView.faceArt(photo, content: content) == (shown ? photo : .none), "\(license)")
        }
        // The card's own art is the birder's or the pack's painting: always on the face.
        let painted: CardText.Art = .packArt(url, credit: nil)
        var choices = SharePolicy.Choices()
        choices.useSnapshot = false
        let none = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: nil, area: nil, choices: choices)
        #expect(ShareCardView.faceArt(painted, content: none) == painted)
    }
}
