import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BirdJournal

// Issue #68: the art-job photo leaves the phone with every face blurred and no metadata. The fixture is NASA's public
// domain portrait of Sally K. Ride (S84-37256; fixtures/README.md, "The face-blur fixture").
@Suite("Art photo: faces blurred, metadata stripped", .serialized)
struct ArtPhotoTests {
    static func fixture() throws -> Data {
        let url = try #require(
            Bundle.allBundles.lazy.compactMap { $0.url(forResource: "face-portrait", withExtension: "jpg") }.first,
            "face-portrait.jpg is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    static func picture(_ jpeg: Data) throws -> CIImage {
        try #require(CIImage(data: jpeg, options: [.applyOrientationProperty: true]))
    }

    /// The fixture rewritten with the metadata a phone photo carries: a place, a time, the device, and an orientation.
    static func withMetadata(_ jpeg: Data, orientation: CGImagePropertyOrientation = .up) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 34.1365, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 118.2942, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 07:42:00", kCGImagePropertyExifLensModel: "Ray-Ban Display"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Meta", kCGImagePropertyTIFFModel: "Ray-Ban Display"],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func properties(_ jpeg: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test("Vision finds the fixture's face, and none is left after the blur")
    func facesAreBlurred() throws {
        let original = try Self.fixture()
        #expect(try ArtPhoto.faceBoxes(in: Self.picture(original)).count == 1)
        let prepared = try ArtPhoto.prepare(jpeg: original)
        #expect(prepared.faces == 1)
        #expect(try ArtPhoto.faceBoxes(in: Self.picture(prepared.jpeg)).isEmpty)
    }

    @Test("The blur changes the face and leaves the rest of the picture alone")
    func onlyTheFaceChanges() throws {
        let original = try Self.picture(Self.fixture())
        let face = try #require(try ArtPhoto.faceBoxes(in: original).first)
        let prepared = try Self.picture(ArtPhoto.prepare(jpeg: Self.fixture()).jpeg)
        #expect(prepared.extent.size == original.extent.size)
        // Inside the face the detail is gone; a corner far from it (the backdrop) is as it was, give or take the JPEG.
        #expect(Self.difference(original, prepared, in: face.insetBy(dx: face.width * 0.2, dy: face.height * 0.2)) > 12)
        #expect(Self.difference(original, prepared, in: CGRect(x: original.extent.maxX - 80, y: original.extent.maxY - 80, width: 60, height: 60)) < 4)
    }

    @Test("No metadata survives: no place, time, device or orientation")
    func metadataIsStripped() throws {
        let tagged = try Self.withMetadata(Self.fixture())
        let before = try Self.properties(tagged)
        #expect(before[kCGImagePropertyGPSDictionary] != nil)
        let after = try Self.properties(ArtPhoto.prepare(jpeg: tagged).jpeg)
        #expect(after[kCGImagePropertyGPSDictionary] == nil)
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] == nil)
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil && exif[kCGImagePropertyExifLensModel] == nil)
        #expect((after[kCGImagePropertyOrientation] as? UInt32 ?? 1) == 1)
    }

    @Test("A photo tagged as turned is written upright, so the painting isn't sideways")
    func orientationIsBakedIn() throws {
        let turned = try Self.withMetadata(Self.fixture(), orientation: .right)
        let prepared = try ArtPhoto.prepare(jpeg: turned)
        let size = try Self.picture(prepared.jpeg).extent.size
        // The 576 × 720 portrait shown turned a quarter is 720 wide.
        #expect(size == CGSize(width: 720, height: 576))
        #expect(prepared.faces == 1)
    }

    @Test("A picture without a face goes through unblurred")
    func noFace() throws {
        let plain = CIImage(color: CIColor(red: 0.4, green: 0.55, blue: 0.35)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let jpeg = try ArtPhoto.encode(plain)
        let prepared = try ArtPhoto.prepare(jpeg: jpeg)
        #expect(prepared.faces == 0)
    }

    @Test("A large library photo leaves scaled down, still with its face blurred and as a JPEG (issue #69)")
    func libraryPhotoScaledDown() throws {
        let original = try Self.picture(try Self.fixture())
        let side = max(original.extent.width, original.extent.height)
        let limit = (side / 2).rounded(.down)
        let prepared = try ArtPhoto.prepare(jpeg: try Self.fixture(), maxSide: limit)
        let picture = try Self.picture(prepared.jpeg)
        #expect(max(picture.extent.width, picture.extent.height) <= limit)
        #expect(max(picture.extent.width, picture.extent.height) >= limit - 1)
        #expect(prepared.faces == 1)
        #expect(try ArtPhoto.faceBoxes(in: picture).isEmpty)
        // Smaller than the limit: untouched in size.
        let small = try Self.picture(try ArtPhoto.prepare(jpeg: try Self.fixture(), maxSide: side * 2).jpeg)
        #expect(small.extent.size == original.extent.size)
    }

    @Test("Bytes that aren't a picture are refused")
    func unreadable() {
        #expect(throws: ArtPhoto.Failure.unreadable) { try ArtPhoto.prepare(jpeg: Data("not a jpeg".utf8)) }
    }

    /// The mean absolute difference of two pictures over a rectangle, on a 0–255 scale.
    static func difference(_ a: CIImage, _ b: CIImage, in rect: CGRect) -> Double {
        let difference = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        let average = difference.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }
}
