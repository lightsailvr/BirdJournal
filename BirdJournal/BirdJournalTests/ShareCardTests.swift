import Album
import Foundation
import ImageIO
import Pack
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #66 and #136 (guide 2.0 page 8): the system share sends the patch on linen with its paper card. The exported image
// carries its pixels and nothing else (no Exif, GPS or TIFF metadata, checked with ImageIO as the postcard was); the patch
// is lit by the shader from a fixed upper-left light (a tilt can't reach it: `PatchLightPixelTests`, which owns the shared
// light); and the card says only what the share may.
@Suite("Share card", .serialized)
@MainActor
struct ShareCardTests {
    static let sighting = SharePolicyTests.sighting
    static let la = PatchEdition.of(setID: "us-ca-la")

    static func facts(place: String? = "Los Angeles", hasPainting: Bool = true, credits: [String] = ["© A. Birder, some rights reserved (CC BY)"], lore: PackLore? = nil) -> PatchShareImage.Facts {
        PatchShareImage.Facts(
            sighting: sighting, name: "Black Phoebe", placement: .numbered(setID: "us-ca-la", setName: "Los Angeles", edition: "Citrus edition", number: 3, total: 160),
            place: place, lore: lore, hasPainting: hasPainting, photoCredits: credits
        )
    }

    static func bundledPatch() async throws -> (facts: PatchShareImage.Facts, loaded: PatchTextures.Loaded) {
        let pack = try SpeciesPack.bundled()
        let species = try #require(pack.species(scientificName: "Haemorhous mexicanus"))
        let patch = try #require(species.patch)
        let art = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground)
        let loaded = try #require(await PatchTextures.load(art, size: .full))
        let facts = PatchShareImage.Facts(
            sighting: sighting, name: species.commonName, placement: .numbered(setID: "us-ca-la", setName: "Los Angeles", edition: "Citrus edition", number: 3, total: 160),
            place: "Pasadena", lore: species.lore, hasPainting: true, photoCredits: PatchShareImage.Facts.credits(of: patch, in: species)
        )
        return (facts, loaded)
    }

    static func rgba(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (bytes, cg.width, cg.height)
    }

    /// One lit patch on white, as the share image draws it, through the same renderer.
    static func litPatch(_ loaded: PatchTextures.Loaded, light: SIMD2<Double>) throws -> UIImage {
        let view = Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay { LitPatch(loaded: loaded, ground: la.twill, sewnTo: StitchTimeline.allSewn, room: 34, fixedLight: light) }
            .frame(width: 240, height: 240)
            .frame(width: 360, height: 360)
            .background(Color.white)
        return try #require(CardExport.render(view, scale: 1)).image
    }

    @Test("the image exports as a PNG with no Exif, GPS or TIFF metadata, and its patch comes to 1080 px")
    func exportHasNoMetadata() async throws {
        let (facts, loaded) = try await Self.bundledPatch()
        let export = try #require(CardExport.render(PatchShareImage(facts: facts, edition: Self.la, loaded: loaded), scale: CardExport.imageScale))

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
        #expect((properties[kCGImagePropertyPixelWidth] as? Int ?? 0) == 1620)
        #expect(PatchShareImage.patchWidth * CardExport.imageScale == 1080)
        #expect(export.png.count < 12_000_000, "a share of \(export.png.count) bytes")
    }

    @Test("the renderer runs the shader, from where the light is told to be")
    func theShaderRuns() async throws {
        let (_, loaded) = try await Self.bundledPatch()
        let upperLeft = try Self.rgba(Self.litPatch(loaded, light: PatchLightModel.rest))
        let lowerRight = try Self.rgba(Self.litPatch(loaded, light: -PatchLightModel.rest))
        #expect(PatchLightPixelTests.meanChange(upperLeft.bytes, lowerRight.bytes) >= 3, "the light has to show in the exported pixels")
    }

    @Test("the image's light is upper-left: the shadow falls lower-right")
    func upperLeftLight() async throws {
        let (_, loaded) = try await Self.bundledPatch()
        #expect(PatchShareImage.light == PatchLightModel.rest)

        // Just outside the round patch on white: darker to the lower right, where the shadow falls, than the upper left.
        let lit = try Self.rgba(Self.litPatch(loaded, light: PatchShareImage.light))
        func luma(_ x: Int, _ y: Int) -> Int {
            let at = (y * lit.width + x) * 4
            return Int(lit.bytes[at]) + Int(lit.bytes[at + 1]) + Int(lit.bytes[at + 2])
        }
        let (centre, reach) = (180.0, 120.0 + 4)
        let offset = Int((reach * 0.7071).rounded())
        let (shadowed, clear) = (luma(Int(centre) + offset, Int(centre) + offset), luma(Int(centre) - offset, Int(centre) - offset))
        #expect(shadowed < clear - 20, "lower right \(shadowed), upper left \(clear)")
    }

    @Test("without a painting the image draws the edition's blank")
    func blankWithoutAPainting() throws {
        let image = PatchShareImage(facts: Self.facts(hasPainting: false, credits: []), edition: Self.la, loaded: nil)
        #expect(CardExport.render(image, scale: 2) != nil)
    }

    @Test("the card says the name, the edition, the place, the date, AI illustration and the wordmark")
    func cardWords() {
        let facts = Self.facts()
        #expect(facts.name == "Black Phoebe")
        let date = Self.sighting.confirmedAt.formatted(date: .abbreviated, time: .omitted)
        #expect(facts.line == "Citrus edition · Los Angeles · \(date)")
        #expect(facts.imprint == "AI illustration · Featherguild")
        #expect(facts.credits == "Patch from a reference photo: © A. Birder, some rights reserved (CC BY).")
    }

    @Test("the story title and its license come from the pack, and the app never invents one")
    func storyTitle() {
        func lore(title: String?) -> PackLore { PackLore(text: "It dips its tail.", tagline: "A dipper.", sources: [], title: title) }
        let titled = Self.facts(lore: lore(title: "Keeper of the Quiet Pond"))
        #expect(titled.storyTitle == "Keeper of the Quiet Pond")
        #expect(titled.credits?.hasSuffix("Story text: CC BY-SA 4.0.") == true)
        #expect(Self.facts(lore: lore(title: "")).storyTitle == nil)
        #expect(Self.facts(lore: nil).storyTitle == nil)
    }

    @Test("the place is only what the share may carry: a secret spot, or none at all with the city off")
    func placeOnTheCard() {
        #expect(Self.facts(place: FindPolicy.secretSpot).line.hasPrefix("Citrus edition · a secret spot · "))
        let off = Self.facts(place: nil).line
        #expect(!off.contains("Los Angeles") && off.hasPrefix("Citrus edition · "))
    }

    @Test("a blank isn't an illustration and credits no photo")
    func blankWords() {
        let facts = Self.facts(hasPainting: false, credits: [])
        #expect(facts.imprint == "Featherguild")
        #expect(facts.credits == nil)
    }
}
