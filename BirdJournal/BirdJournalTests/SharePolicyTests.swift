import Album
import Foundation
import ImageIO
import Pack
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #28: what a shared sighting carries. The precise location never does; the picture's credit always does;
// a photo whose license does not allow redistribution is left out.
@Suite("Share policy")
struct SharePolicyTests {
    static let sighting = Sighting(
        speciesID: "Sayornis nigricans_Black Phoebe",
        confirmedAt: Date(timeIntervalSince1970: 1_790_000_000),
        location: Coordinate(latitude: 34.1365, longitude: -118.2942, accuracy: 12),
        soundConfidence: 0.82,
        frameImagePath: "frame.jpg",
        source: .glasses,
        note: "Tail dipping over the pond."
    )

    static func photo(license: String) -> PackPhoto {
        PackPhoto(
            id: "1", speciesID: "sayornis-nigricans", rank: 0, lensFile: "lens/1.jpg", phoneFile: "phone/1.jpg", observer: "A. Birder",
            observerLogin: "abirder", license: license, creditLine: "© A. Birder, some rights reserved (\(license))", shortCredit: "Photo: A. Birder, \(license)",
            sourceURL: URL(string: "https://www.inaturalist.org/observations/1")!, photoURL: URL(string: "https://example.com/1.jpg")!, inatPhotoID: 1, score: 1
        )
    }

    static let english = Locale(identifier: "en_US")

    @Test("the chosen fields go on the card and in the text; the coordinate never does")
    func chosenFields() {
        var choices = SharePolicy.Choices()
        choices.includeNote = true
        let content = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "CC BY"), area: "Los Angeles, CA", choices: choices, locale: Self.english)

        #expect(content.commonName == "Black Phoebe")
        #expect(content.dateText == "Sep 21, 2026")
        #expect(content.areaText == "Los Angeles, CA")
        #expect(content.note == "Tail dipping over the pond.")
        #expect(content.picture == .snapshot(framePath: "frame.jpg"))
        #expect(content.attribution == nil, "the birder's own frame needs no credit")
        let text = SharePolicy.text(for: content)
        #expect(text.contains("Black Phoebe (Sayornis nigricans) · Sep 21, 2026 · Los Angeles, CA"))
        #expect(text.contains("“Tail dipping over the pond.”"))
        #expect(text.contains("Powered by BirdNET"))
        #expect(!text.contains("34.1") && !text.contains("118.2"), "no coordinate in the text")

        var none = SharePolicy.Choices()
        none.includeDate = false
        none.includeArea = false
        let bare = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: nil, area: "Los Angeles, CA", choices: none, locale: Self.english)
        #expect(bare.dateText == nil && bare.areaText == nil && bare.note == nil)
        #expect(SharePolicy.text(for: bare) == "Black Phoebe (Sayornis nigricans)\nHeard with Bird Journal · Powered by BirdNET")
    }

    @Test("a reference photo carries its observer, license and source; one under a license that does not allow sharing is left out")
    func referenceAttribution() {
        var choices = SharePolicy.Choices()
        choices.useSnapshot = false
        let shared = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "CC BY-NC"), area: nil, choices: choices, locale: Self.english)
        #expect(shared.picture == .reference(Self.photo(license: "CC BY-NC")))
        #expect(shared.pictureCaption == "Reference photo · Photo: A. Birder, CC BY-NC")
        #expect(shared.attribution == "Photo: © A. Birder, some rights reserved (CC BY-NC), via iNaturalist https://www.inaturalist.org/observations/1")
        #expect(SharePolicy.text(for: shared).hasSuffix("via iNaturalist https://www.inaturalist.org/observations/1"))

        let reserved = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: Self.photo(license: "All rights reserved"), area: nil, choices: choices, locale: Self.english)
        #expect(reserved.picture == .none)
        #expect(reserved.attribution == nil)
        #expect(!SharePolicy.mayShare(Self.photo(license: "CC BY-ND")))
        #expect(SharePolicy.mayShare(Self.photo(license: "CC0")))
    }

    @Test("the rendered card is a PNG with no location, camera or other metadata")
    @MainActor
    func exportHasNoMetadata() throws {
        var choices = SharePolicy.Choices()
        choices.useSnapshot = false
        let content = SharePolicy.content(for: Self.sighting, commonName: "Black Phoebe", reference: nil, area: "Los Angeles, CA", choices: choices, locale: Self.english)
        let renderer = ImageRenderer(content: PostcardView(content: content, pack: nil, frameStore: nil).frame(width: 360))
        renderer.scale = 2
        let image = try #require(renderer.uiImage?.cgImage)
        let png = try #require(PostcardExport.png(image))

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
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
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) >= 700)
    }
}
