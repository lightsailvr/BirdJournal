import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #222 (of #206): a bird outside every set wears the app's one generic embroidered patch, with its name on a paper tag,
// where Uncharted's blank used to be. A set's own blank, and "Being sewn", are as they were.
@Suite("Uncharted's generic patch", .serialized)
@MainActor
struct UnchartedPatchTests {
    /// A phone with no pack at all: the generic patch ships in the app, not in a pack.
    private static func emptyLibrary() -> PackLibrary {
        PackLibrary(bundled: nil, storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "UnchartedPatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)))
    }

    /// `view` alone in a window `side` points square, on black: a render of it is `side` pixels each way, with no safe area
    /// moving it.
    static func window(_ view: some View, side: CGFloat) throws -> (window: UIWindow, host: UIViewController) {
        let host = UIHostingController(rootView: view.frame(width: side, height: side).background(Color.black).ignoresSafeArea())
        host.safeAreaRegions = []
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = try UIWindow(windowScene: #require(scene))
        window.frame = CGRect(x: 0, y: 0, width: side, height: side)
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    /// `view` at `side` points square on black, as `side` by `side` pixels.
    static func render(_ view: some View, side: CGFloat = 300, settle: Duration = .seconds(1)) async throws -> [UInt8] {
        let (window, host) = try window(view, side: side)
        defer { window.isHidden = true }
        try await Task.sleep(for: settle)
        let pixels = PatchLightPixelTests.pixels(of: host.view)
        #expect(pixels.count == Int(side) * Int(side) * 4, "a render of \(pixels.count / 4) pixels for \(side) points square")
        return pixels
    }

    // MARK: - A set's blank is as it was

    @Test("a set's patch without its painting is still its edition's blank with the bird's name on its tag", arguments: ["us-ca-sd", "us-pnw", "a-set-the-app-does-not-know"])
    func aSetsBlankStays(setID: String) async throws {
        let edition = PatchEdition.of(setID: setID)
        let shown = try await Self.render(PatchView(state: .tagged, edition: edition, size: .full, tag: "Northern Rough-winged Swallow"))
        let blank = try await Self.render(Color.clear.aspectRatio(edition.aspect, contentMode: .fit).overlay { PatchBlank(edition: edition, tag: "Northern Rough-winged Swallow") })
        #expect(blank.contains { $0 > 0 }, "nothing rendered")
        #expect(PatchLightPixelTests.meanChange(shown, blank) < 0.01, "they differ by \(PatchLightPixelTests.meanChange(shown, blank))")
    }

    @Test("a set's patch whose pack is on its way is still its edition's blank saying Being sewn")
    func beingSewnStays() async throws {
        let edition = PatchEdition.of(setID: "us-ca-sd")
        let shown = try await Self.render(PatchView(state: .beingSewn, edition: edition, size: .full, tag: "Verdin"))
        let blank = try await Self.render(Color.clear.aspectRatio(edition.aspect, contentMode: .fit).overlay { PatchBlank(edition: edition, beingSewn: true) })
        let named = try await Self.render(Color.clear.aspectRatio(edition.aspect, contentMode: .fit).overlay { PatchBlank(edition: edition, tag: "Verdin") })
        #expect(PatchLightPixelTests.meanChange(shown, blank) < 0.01, "they differ by \(PatchLightPixelTests.meanChange(shown, blank))")
        #expect(PatchLightPixelTests.meanChange(shown, named) > 0.05, "the control: Being sewn isn't the bird's name")
    }

    // MARK: - Outside every set

    @Test("outside every set, any bird's patch is the app's one generic patch, and it's on a phone with no pack")
    func oneForEveryBird() async throws {
        let library = Self.emptyLibrary()
        let blackbird = try #require(library.patchArt(scientificName: "Turdus merula", setID: nil), "a bird no pack describes")
        #expect(library.patchArt(scientificName: "Calypte anna", setID: nil) == blackbird, "the same embroidery for every bird")
        #expect(library.patchArtState(scientificName: "Turdus merula", setID: nil) == .painted(blackbird))
        let full = try #require(await PatchTextures.load(blackbird, size: .full))
        #expect(full.colourBitmap.width == 720 && full.colourBitmap.height == 720)
        #expect(full.layersBitmap.width == 360 && full.layersBitmap.height == 360)
        #expect(await PatchTextures.load(blackbird, size: .thumbnail) != nil)
    }

    // MARK: - On screen

    private static let uncharted = PatchEdition.of(setID: nil)

    private static func generic() async throws -> PatchArt {
        let art = try #require(PatchArt.uncharted)
        #expect(art.isGeneric)
        // Decoded before it's drawn, so a render is the lit patch from its first frame.
        _ = try #require(await PatchTextures.load(art, size: .full))
        _ = try #require(await PatchTextures.load(art, size: .thumbnail))
        return art
    }

    /// The mean change per channel between two renders of a `side`-point square, over the part of it between these fractions.
    private static func change(_ first: [UInt8], _ second: [UInt8], side: Int, rows: ClosedRange<Double>, columns: ClosedRange<Double> = 0...1) -> Double {
        var total = 0, count = 0
        for y in Int(rows.lowerBound * Double(side))..<min(side, Int(rows.upperBound * Double(side))) {
            for x in Int(columns.lowerBound * Double(side))..<min(side, Int(columns.upperBound * Double(side))) {
                let at = (y * side + x) * 4
                for channel in 0..<3 { total += abs(Int(first[at + channel]) - Int(second[at + channel])) }
                count += 3
            }
        }
        return Double(total) / Double(max(count, 1))
    }

    /// The feather lies between 0.68 and 0.86 of the way down the round (`art/uncharted-patch.json`'s `emblem_box`).
    private static let feather = (rows: 0.70...0.84, columns: 0.25...0.75)

    @Test("it's embroidery where the blank was bare canvas, with the bird's name on a paper tag over it")
    func embroideryAndTag() async throws {
        let art = try await Self.generic()
        let patch = try await Self.render(PatchView(state: .painted(art), edition: Self.uncharted, size: .full, tag: "Verdin"))
        let untagged = try await Self.render(PatchView(art: art, edition: Self.uncharted, size: .full))
        let blank = try await Self.render(PatchBlank(edition: Self.uncharted, tag: "Verdin"))
        let onCanvas = Self.change(patch, blank, side: 300, rows: Self.feather.rows, columns: Self.feather.columns)
        #expect(onCanvas > 12, "the feather, where the blank has bare canvas: \(onCanvas)")
        let tag = Self.change(patch, untagged, side: 300, rows: 0.1...0.4, columns: 0.3...0.7)
        #expect(tag > 12, "the tag hangs over the lit patch: \(tag)")
        let underTag = Self.change(patch, untagged, side: 300, rows: Self.feather.rows)
        #expect(underTag < 0.5, "and leaves the feather alone: \(underTag)")
    }

    /// How far down a `side`-point patch its tag reaches, as a part of its height: the lowest row the tag changes.
    private static func tagReach(_ name: String, side: CGFloat, size: PatchTextures.Size, typeSize: DynamicTypeSize, art: PatchArt) async throws -> Double {
        let tagged = try await render(PatchView(state: .painted(art), edition: uncharted, size: size, tag: name).environment(\.dynamicTypeSize, typeSize), side: side)
        let untagged = try await render(PatchView(art: art, edition: uncharted, size: size).environment(\.dynamicTypeSize, typeSize), side: side)
        let pixels = Int(side)
        let lowest = (0..<pixels).last { y in
            (0..<pixels).contains { x in
                let at = (y * pixels + x) * 4
                return (0..<3).contains { abs(Int(tagged[at + $0]) - Int(untagged[at + $0])) > 24 }
            }
        }
        return Double(try #require(lowest, "no tag on a \(side)-point patch")) / Double(pixels)
    }

    @Test("a three-line name's tag ends above the feather on a board's tile, at every text size", arguments: [
        (104.0, DynamicTypeSize.large), (114, .large), (124, .large), (124, .xxxLarge), (104, .xSmall),
    ])
    func tagClearsTheFeatherOnATile(side: Double, typeSize: DynamicTypeSize) async throws {
        let art = try await Self.generic()
        let reach = try await Self.tagReach("Northern Rough-winged Swallow", side: side, size: .thumbnail, typeSize: typeSize, art: art)
        print("uncharted tag reach on a \(side)-point tile at \(typeSize):", reach)
        #expect(reach > 0.3, "the tag is there: \(reach)")
        #expect(reach < 0.678, "the tag ends \(reach) of the way down; the feather starts at 0.678")
    }

    @Test("and on its page, and where one column of large text makes the patch 200 points", arguments: [
        (286.0, DynamicTypeSize.large), (286, .xxxLarge), (200, .accessibility5), (190, .large),
    ])
    func tagClearsTheFeatherOnAPage(side: Double, typeSize: DynamicTypeSize) async throws {
        let art = try await Self.generic()
        let reach = try await Self.tagReach("Northern Rough-winged Swallow", side: side, size: .full, typeSize: typeSize, art: art)
        print("uncharted tag reach on a \(side)-point patch at \(typeSize):", reach)
        #expect(reach > 0.25, "the tag is there: \(reach)")
        #expect(reach < 0.678, "the tag ends \(reach) of the way down; the feather starts at 0.678")
    }

    @Test("a ten-degree tilt visibly changes it, whichever way, as it does a pack's patch, and a still phone changes nothing")
    func tilt() async throws {
        let art = try await Self.generic()
        let (window, host) = try Self.window(PatchView(state: .painted(art), edition: Self.uncharted, size: .full, tag: "Verdin"), side: 300)
        defer { window.isHidden = true; PatchLight.shared.restart() }

        let light = PatchLight.shared
        func settle(rightEdgeDown: Double = 0, topEdgeUp: Double = 0) async throws -> [UInt8] {
            for _ in 0..<120 { light.take(PatchLightTests.gravity(rightEdgeDown: rightEdgeDown, topEdgeUp: topEdgeUp)) }
            try await Task.sleep(for: .milliseconds(500))
            return PatchLightPixelTests.pixels(of: host.view)
        }

        light.restart()
        let rest = try await settle()
        let still = try await settle()
        #expect(PatchLightPixelTests.meanChange(rest, still) < 0.1, "a still phone changes nothing")

        let measured = [
            ("right edge down", try await settle(rightEdgeDown: 10)),
            ("right edge up", try await settle(rightEdgeDown: -10)),
            ("top edge up", try await settle(topEdgeUp: 10)),
            ("top edge down", try await settle(topEdgeUp: -10)),
        ].map { ($0.0, PatchLightPixelTests.meanChange(rest, $0.1), Self.change(rest, $0.1, side: 300, rows: 0.3...0.6, columns: 0.3...0.7)) }
        print("uncharted patch light change at 10 degrees (whole patch, bare canvas):", measured)
        for (tilt, change, canvas) in measured {
            #expect(change >= 3, "\(tilt) by 10° changed the patch by only \(change) of 255 per channel")
            #expect(canvas > 0.5, "\(tilt) by 10° changed the canvas's weave by only \(canvas)")
        }
    }

    // MARK: - As a flat picture

    @Test("the widget's and the recap's flat picture is the lit patch with the name on its tag, not the blank")
    func flatPicture() async throws {
        let art = try await Self.generic()
        let loaded = try #require(await PatchTextures.load(art, size: .full))
        func picture(loaded: PatchTextures.Loaded?, isGeneric: Bool) throws -> (bytes: [UInt8], side: Int) {
            let image = try #require(FlatPatch.render(loaded: loaded, edition: Self.uncharted, tag: "Verdin", isGeneric: isGeneric, width: 160, scale: 1))
            let (bytes, width, height) = try ShareCardTests.rgba(image)
            #expect(width == height)
            return (bytes, width)
        }
        let flat = try picture(loaded: loaded, isGeneric: true)
        let untagged = try picture(loaded: loaded, isGeneric: false)
        let blank = try picture(loaded: nil, isGeneric: false)
        // The patch is 160 of the picture's 188 points, with the shadow's room around it.
        let room = Double(FlatPatch.room) / Double(flat.side), face = 160 / Double(flat.side)
        func rows(_ part: ClosedRange<Double>) -> ClosedRange<Double> { (room + part.lowerBound * face)...(room + part.upperBound * face) }
        #expect(Self.change(flat.bytes, blank.bytes, side: flat.side, rows: rows(Self.feather.rows), columns: rows(Self.feather.columns)) > 12, "the feather")
        #expect(Self.change(flat.bytes, untagged.bytes, side: flat.side, rows: rows(0.1...0.45), columns: rows(0.3...0.7)) > 8, "the name's tag")
    }

    @Test("the widget's latest patch outside every set is the generic patch, and a widget still holding the blank is drawn again")
    func widget() async throws {
        let album = try AlbumSchema.makeContainer(inMemory: true)
        let library = Self.emptyLibrary()
        let collection = CollectionStore(container: album, sets: { library.cardSets })
        let store = WidgetStore(directory: URL.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)", directoryHint: .isDirectory))
        album.mainContext.insert(Sighting(speciesID: "Turdus merula_Common Blackbird", confirmedAt: .now, location: nil, soundConfidence: 0.9, source: .phone))
        try album.mainContext.save()

        // What the last version left: the words, marked as no painting, and the blank's picture.
        let before = LatestPatchPublisher(store: store, collection: collection, packs: library, draw: { _ in .init(png: Data([1, 2, 3]), isLit: false) })
        await before.write()
        #expect(store.snapshot()?.latest?.hasPainting == false)
        #expect(store.patchImage() == Data([1, 2, 3]))

        await LatestPatchPublisher(store: store, collection: collection, packs: library, isInFront: { true }).write()
        let written = try #require(store.snapshot()?.latest)
        #expect(written.name == "Common Blackbird" && written.setName == "Uncharted" && written.link.setID == nil)
        #expect(written.hasPainting, "the generic patch is a painting, lit")
        let png = try #require(store.patchImage())
        let image = try #require(UIImage(data: png))
        let (bytes, width, height) = try ShareCardTests.rgba(image)
        #expect(bytes[3] == 0, "the corner is clear")
        // The brown thread of the feather's tip, where the blank had pale canvas: brown by how much of its colour is colour,
        // since lit canvas is dark too in the shade of its weave.
        let room = Double(FlatPatch.room * LatestPatchPublisher.patchScale), face = Double(LatestPatchPublisher.patchWidth * LatestPatchPublisher.patchScale)
        var dark = 0, counted = 0
        for y in Int(room + 0.70 * face)..<Int(room + 0.80 * face) {
            for x in Int(room + 0.50 * face)..<Int(room + 0.78 * face) where y < height && x < width {
                let at = (y * width + x) * 4
                counted += 1
                let (most, least) = (max(bytes[at], bytes[at + 1], bytes[at + 2]), min(bytes[at], bytes[at + 1], bytes[at + 2]))
                if Double(most - least) > 0.45 * Double(most) { dark += 1 }
            }
        }
        #expect(Double(dark) / Double(max(counted, 1)) > 0.4, "\(dark) of \(counted) pixels are the feather's brown thread")
    }

    // MARK: - Its credit, and whose painting it is

    @Test("it's credited as an AI illustration, and never with a bird's reference photo")
    func credit() throws {
        let generic = try #require(PatchArt.uncharted)
        let pack = try SpeciesPack.bundled()
        let species = try #require(pack.species.first { species in species.patch.map { !PatchShareImage.Facts.credits(of: $0, in: species).isEmpty } ?? false }, "a bird whose patch credits a photo")
        let patch = try #require(species.patch)
        let own = PatchArt(colour: pack.patchURL(for: patch), layers: pack.patchLayersURL(for: patch), ground: patch.ground)
        #expect(!PatchShareImage.Facts.photoCredits(of: own, species: species).isEmpty, "the control: its own painting credits its photo")
        #expect(PatchShareImage.Facts.photoCredits(of: generic, species: species).isEmpty, "the generic patch was painted from no photo")
        #expect(PatchShareImage.Facts.photoCredits(of: nil, species: species).isEmpty, "nor is a blank")
        #expect(UnchartedPatchCredit.text.hasPrefix("AI illustration, not a photograph"))
    }

    @Test("a Guild's find that names no set still borrows the bird's painting from an edition on the phone, and is the generic patch when there's none")
    func guildFinds() throws {
        let pack = try SpeciesPack.bundled()
        let painted = try #require(pack.species.first { $0.patch != nil })
        let withPack = PackLibrary(bundled: pack, storage: PackStorage(directory: URL.temporaryDirectory.appending(path: "UnchartedPatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)))
        let borrowed = withPack.guildPatchArtwork(scientificName: painted.scientificName, setID: nil)
        #expect(borrowed.setID == pack.info.id)
        #expect(borrowed.state.art?.isGeneric == false)
        #expect(borrowed.note != nil, "labelled as another edition's artwork")
        let none = Self.emptyLibrary().guildPatchArtwork(scientificName: painted.scientificName, setID: nil)
        #expect(none.setID == nil && none.note == nil)
        let generic = try #require(PatchArt.uncharted)
        #expect(none.state == .painted(generic))
    }
}

// What VoiceOver reads of the generic patch (spec #206, story 32), walked as VoiceOver walks it: XCUITest lists what SwiftUI
// hides. The patch and its paper tag are a picture; the words are the tile's and the page's.
@Suite("Uncharted's generic patch, for VoiceOver", .serialized)
@MainActor
struct UnchartedPatchAccessibilityTests {
    private static let blackbird = "Turdus merula_Common Blackbird"

    /// A collection of one bird no set takes: saved with no location.
    private static func harness() throws -> ScreenAccessibilityTests.Harness {
        let harness = try ScreenAccessibilityTests.Harness(seeded: false)
        harness.album.mainContext.insert(Sighting(speciesID: blackbird, confirmedAt: .now, location: nil, soundConfidence: 0.8, source: .phone))
        try harness.album.mainContext.save()
        #expect(harness.library.patchArtState(scientificName: "Turdus merula", setID: nil).art?.isGeneric == true)
        return harness
    }

    @Test("its board, its page and its paper card read the bird's name and Uncharted, and nothing of the tag twice", arguments: ScreenAccessibilityTests.sizes)
    func readsTheNameAndUncharted(typeSize: DynamicTypeSize) async throws {
        let harness = try Self.harness()
        let spoken = "Common Blackbird, Uncharted patch, seen once, sewn "
        let state = CollectionState()
        state.board = .uncharted
        let board = try await ScreenAccessibilityTests.walk(JournalView(state: state), harness: harness, typeSize: typeSize) { $0.contains { $0.hasPrefix(spoken) } }
        ScreenAccessibilityTests.expectClean(board, screen: "Uncharted board")
        #expect(board.count { $0.hasPrefix(spoken) } == 1, "the tile is one element: \(board)")
        #expect(!board.contains("Common Blackbird"), "the tag's words aren't read on their own: \(board)")
        #expect(!board.contains { $0.hasSuffix(", art on its way") }, "nothing is on its way: \(board)")

        let key = CardCollection.Patch.Key(speciesID: Self.blackbird, setID: nil)
        let page = try await ScreenAccessibilityTests.walk(PatchDetailView(key: key), harness: harness, typeSize: typeSize) { $0.contains("Turn over") && $0.contains { $0.hasPrefix(spoken) } }
        ScreenAccessibilityTests.expectClean(page, screen: "Uncharted patch page")
        #expect(page.count { $0.hasPrefix(spoken) } == 1, "the patch in words, once: \(page)")
        #expect(page.count { $0 == "Common Blackbird" } == 1, "the name in type under it, and not the tag's: \(page)")
        #expect(page.contains("Uncharted"), "its edition line: \(page)")

        let card = try await ScreenAccessibilityTests.walk(PatchDetailView(key: key, startsTurned: true), harness: harness, typeSize: typeSize) { $0.contains("Turn back") && $0.contains("Uncharted, outside every set") }
        ScreenAccessibilityTests.expectClean(card, screen: "Uncharted paper card")
        #expect(card.contains("Uncharted, outside every set"), "\(card)")
        #expect(card.contains("Common Blackbird"), "\(card)")
        #expect(card.contains("AI illustration"), "the generic patch is one: \(card)")
    }
}
