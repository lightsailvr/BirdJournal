import Album
import CoreLocation
import Foundation
import ImageIO
import MapKit
import Pack
import SQLite3
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

/// The Atlas as a book (issue #150, slice 9): what a set's row shows, a map marker's picture, a record's words and a first photo's slot.
@Suite("The Atlas as a book")
@MainActor
struct AtlasBookTests {
    private static let goose = "Branta canadensis"
    private static let setID = "us-ca-la"

    private func collection(with sightings: [Sighting], sets: [CardSet]) -> CardCollection {
        CardCollection(sightings: sightings, sets: sets)
    }

    // MARK: - A set's row

    @Test("a bird still out there shows its silhouette from the set's own pack, tinted at draw time from a file on disk")
    func silhouetteRow() throws {
        let pack = try SpeciesPack.bundled()
        let source = RowPictureSource.ofSetRow(scientificName: Self.goose, isFound: false, reference: nil, pack: pack)
        guard case .silhouette(let url?) = source else {
            Issue.record("\(source)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test("with the set's pack not on the phone, or no silhouette for the bird, it's the glyph")
    func glyphFallback() throws {
        #expect(RowPictureSource.ofSetRow(scientificName: Self.goose, isFound: false, reference: nil, pack: nil) == .silhouette(nil), "no pack")
        let pack = try SpeciesPack.bundled()
        #expect(RowPictureSource.ofSetRow(scientificName: "Nonesuch nonesuch", isFound: false, reference: nil, pack: pack) == .silhouette(nil), "not in the pack")
        // A pack built before silhouettes: the same database, with no such table.
        let folder = URL.temporaryDirectory.appending(path: "AtlasBookTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appending(path: "pack.sqlite")
        try FileManager.default.copyItem(at: pack.directory.appending(path: "pack.sqlite"), to: database)
        var connection: OpaquePointer?
        #expect(sqlite3_open(database.path(percentEncoded: false), &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "DROP TABLE silhouette", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        let older = try SpeciesPack.open(directory: folder)
        #expect(older.species.count == 160)
        #expect(RowPictureSource.ofSetRow(scientificName: Self.goose, isFound: false, reference: nil, pack: older) == .silhouette(nil), "a pack built before silhouettes")
    }

    @Test("a bird you've found shows its reference photo, pack or no pack: the Atlas has no patches in it")
    func foundBirdRow() throws {
        let pack = try SpeciesPack.bundled()
        let url = URL(fileURLWithPath: "/reference.jpg")
        for pack in [pack, nil] {
            #expect(RowPictureSource.ofSetRow(scientificName: Self.goose, isFound: true, reference: url, pack: pack) == .reference(url))
        }
    }

    @Test("the silhouette is drawn in the mark's colour, on its tile, and the glyph falls back when the file's gone")
    func silhouetteDraws() async throws {
        let pack = try SpeciesPack.bundled()
        let species = try #require(pack.species(scientificName: Self.goose))
        let url = pack.silhouetteURL(for: try #require(species.silhouette))
        _ = try #require(await SilhouetteImages.load(url))
        #expect(SilhouetteImages.cached(url) != nil, "a row scrolled back to doesn't load it again")
        let missing = await SilhouetteImages.load(URL(fileURLWithPath: "/nonexistent/none.png"))
        #expect(missing == nil)

        let tile = ImageRenderer(content: SpeciesSilhouette(url: url).frame(width: 63, height: 63).environment(\.colorScheme, .dark))
        tile.scale = 1
        let image = try #require(tile.uiImage?.cgImage)
        let colours = try Self.colours(of: image)
        let raised = UIColor(named: "JournalRaised")!.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let tileColour = Self.rgb(raised)
        let marked = colours.filter { colour -> Bool in
            let distance: CGFloat = abs(colour.0 - tileColour.0) + abs(colour.1 - tileColour.1) + abs(colour.2 - tileColour.2)
            return distance > 0.2
        }
        #expect(marked.count > 300, "the goose's shape covers part of the tile, not none: \(marked.count)")
        #expect(marked.count < 63 * 63 * 3 / 4, "and it's a shape, not a filled tile: \(marked.count)")
        #expect(marked.allSatisfy { $0.0 < 0.95 || $0.1 < 0.95 }, "tinted, not the file's white")
    }

    // MARK: - A map marker

    @Test("a marker is a flat picture in its edition's shape: the corners clear, the patch's own proportions", arguments: EditionTintTests.setIDs.map(Optional.some) + [nil])
    func markerShape(setID: String?) throws {
        let edition = PatchEdition.of(setID: setID)
        let image = MapPatchThumbnail.draw(painting: nil, edition: edition)
        let rect = MapPatchThumbnail.patchRect(edition: edition, side: MapPatchThumbnail.side)
        #expect(max(rect.width, rect.height) == MapPatchThumbnail.side)
        #expect(abs(rect.width / rect.height - edition.aspect) < 0.01)
        #expect(abs(image.size.width - (rect.width + MapPatchThumbnail.room * 2)) < 0.5)
        let cg = try #require(image.cgImage)
        let alpha = try Self.alpha(of: cg)
        let scale = Int(image.scale)
        let centre = (Int(image.size.width / 2) * scale, Int(image.size.height / 2) * scale)
        #expect(alpha(centre.0, centre.1) > 0.99, "the cloth")
        #expect(alpha(0, 0) < 0.01, "a corner: the map shows through")
    }

    @Test("a marker with a painting draws it, once: the finished picture comes back for every sighting of that bird")
    func markerPainting() async throws {
        let pack = try SpeciesPack.bundled()
        let found = try #require(pack.species(scientificName: Self.goose)?.patch)
        let art = PatchArt(colour: pack.patchURL(for: found), layers: pack.patchLayersURL(for: found), ground: found.ground, stitchBounds: found.stitchBounds)
        let edition = PatchEdition.of(setID: Self.setID)
        let done = await MapPatchThumbnail.load(art: art, edition: edition)
        #expect(MapPatchThumbnail.immediate(art: art, edition: edition) === done)
        let blank = MapPatchThumbnail.immediate(art: nil, edition: edition)
        #expect(done !== blank, "a painting, not the blank")
    }

    @Test("a cluster's picture is one size whatever its count, so a new count or painting changes nothing MapKit lays out")
    func clusterIsOneSize() {
        let patch = MapPatchThumbnail.draw(painting: nil, edition: PatchEdition.of(setID: Self.setID))
        for count in [2, 31, 999, 5000] {
            let picture = MapPatchThumbnail.cluster(patch, count: count, tint: .red, ink: .white)
            #expect(picture.size == MapPatchThumbnail.clusterSize, "\(count)")
        }
    }

    @Test("a cluster is listed when no zoom would part it, and zoomed into when one would")
    func oneSpot() {
        let griffith = CLLocationCoordinate2D(latitude: 34.1365, longitude: -118.2942)
        #expect(SightingMap.isOneSpot([griffith, griffith]))
        #expect(SightingMap.isOneSpot([griffith, CLLocationCoordinate2D(latitude: 34.13652, longitude: -118.29422)]), "a few metres of GPS")
        #expect(!SightingMap.isOneSpot([griffith, CLLocationCoordinate2D(latitude: 34.1402, longitude: -118.2898)]), "the pond, half a kilometre off")
    }

    // MARK: - The record

    @Test("an empty answer from the geocoder is no name, so the place keeps its coordinate rather than reading \"Near\"")
    func emptyPlaceName() {
        #expect(PlaceNames.usableName(cityWithContext: "Los Angeles, CA", city: "Los Angeles") == "Los Angeles, CA")
        #expect(PlaceNames.usableName(cityWithContext: "", city: "Los Angeles") == "Los Angeles")
        #expect(PlaceNames.usableName(cityWithContext: " ", city: "") == nil)
        #expect(PlaceNames.usableName(cityWithContext: nil, city: nil) == nil)
    }

    @Test("a record says how you met the bird, and changes with Heard and Seen")
    func how() {
        let sighting = Sighting(speciesID: "\(Self.goose)_Canada Goose", confirmedAt: .now, soundConfidence: 0.8, source: .phone)
        #expect(CardText.how(sighting) == "Heard with iPhone microphone")
        sighting.method = .seen
        #expect(CardText.how(sighting) == "Seen, and heard with iPhone microphone")
        let glasses = Sighting(speciesID: "\(Self.goose)_Canada Goose", confirmedAt: .now, soundConfidence: 0.8, source: .glasses)
        #expect(CardText.how(glasses) == "Heard with Ray-Ban Display")
    }

    // MARK: - A first photo

    @Test("a reference photo's slot is the photo's own shape, so a portrait crop keeps its head and feet")
    func photoSlot() {
        #expect(PhotoSlot.aspect(width: 800, height: 1000) == 0.8)
        #expect(PhotoSlot.aspect(width: 1200, height: 800) == 1.5)
        #expect(PhotoSlot.aspect(width: 400, height: 1000) == PhotoSlot.tallest, "only something narrower than any of the pack's is cropped")
        #expect(PhotoSlot.aspect(width: 0, height: 0) == PhotoSlot.standard)
    }

    @Test("Los Angeles's first photos all fit their slot uncropped")
    func everyFirstPhotoFits() throws {
        let pack = try SpeciesPack.bundled()
        for species in pack.species {
            let photo = try #require(species.photos.first, "\(species.commonName)")
            let url = pack.phoneImageURL(for: photo)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = try #require(properties[kCGImagePropertyPixelWidth] as? CGFloat)
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? CGFloat)
            #expect(abs(PhotoSlot.aspect(of: url) - width / height) < 0.001, "\(species.commonName): \(width) by \(height)")
        }
    }

    // MARK: - Words

    @Test("with nothing to offer yet, a set's page says the field guide comes with the list, not that a Download is there")
    func notOnPhoneWords() {
        #expect(SetView.notOnPhoneText(canDownload: true).contains("downloading it adds"))
        let waiting = SetView.notOnPhoneText(canDownload: false)
        #expect(waiting.contains("once the list of sets comes through"))
        #expect(!waiting.contains("downloading it adds"))
    }

    // MARK: - Pixels

    private static func rgb(_ colour: UIColor) -> (CGFloat, CGFloat, CGFloat) {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    private static func bytes(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private static func colours(of image: CGImage) throws -> [(CGFloat, CGFloat, CGFloat)] {
        let pixels = try bytes(of: image)
        var colours: [(CGFloat, CGFloat, CGFloat)] = []
        for start in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[start]) / 255
            let green = CGFloat(pixels[start + 1]) / 255
            let blue = CGFloat(pixels[start + 2]) / 255
            colours.append((red, green, blue))
        }
        return colours
    }

    private static func alpha(of image: CGImage) throws -> (Int, Int) -> CGFloat {
        let pixels = try bytes(of: image)
        let width = image.width
        return { x, y in CGFloat(pixels[(y * width + x) * 4 + 3]) / 255 }
    }
}
