import Album
import Foundation
import Pack
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import BirdJournal

// Issue #214 (of #206): the Continental edition, the patch of the North America set. The maintainer picked candidate E of
// #213 "as painted": a wide rectangle with softly rounded corners, golden cord, lavender-grey twill. Its seven samples came
// out 1.35 to 1.57 wide to 1 tall (the two kept ones 1.41 and 1.40; 1.42 and 1.43 without the rim of card the pack trims),
// so the app draws it 1.42 wide. The North America pack doesn't exist yet (#215), so the set here is a stand-in: its id, its
// names, two of its birds and a box over the middle of the continent.
@Suite("The Continental edition", .serialized)
@MainActor
struct ContinentalEditionTests {
    typealias Screens = ScreenAccessibilityTests

    static let setID = "north-america"
    static let northAmerica = CardSet(id: setID, name: "North America", edition: "Continental edition", species: ["Corvus brachyrhynchos", "Turdus migratorius"], regions: [
        CardSet.Region(name: "The middle of the continent", polygons: [[[
            CardSet.Point(longitude: -110, latitude: 30), CardSet.Point(longitude: -85, latitude: 30), CardSet.Point(longitude: -85, latitude: 48), CardSet.Point(longitude: -110, latitude: 48), CardSet.Point(longitude: -110, latitude: 30),
        ]]]),
    ])
    static let robin = "Turdus migratorius_American Robin"
    static let kansas = Coordinate(latitude: 38.5, longitude: -98.3, accuracy: 10)
    static let edition = PatchEdition.of(setID: setID)
    static let light = UITraitCollection { $0.userInterfaceStyle = .light }

    /// The app's objects with one robin found in Kansas, and a collection that knows the stand-in set.
    static func found() throws -> (harness: Screens.Harness, store: CollectionStore, patch: CardCollection.Patch) {
        let harness = try Screens.Harness(seeded: false)
        harness.album.mainContext.insert(Sighting(speciesID: robin, confirmedAt: .now, location: kansas, soundConfidence: 0.9, source: .phone))
        try harness.album.mainContext.save()
        let store = CollectionStore(container: harness.album, sets: { [northAmerica] })
        let patch = try #require(store.collection.patches(in: setID).first)
        return (harness, store, patch)
    }

    /// The picked candidate, as #213 recorded it.
    static func picked() throws -> [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "art/continental-candidates.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return try #require((json["candidates"] as? [String: Any])?["E"] as? [String: Any])
    }

    // MARK: - What it is

    @Test("it is the picked candidate: a wide rectangle, 1.42 to 1 as its samples were painted, in its cord and twill")
    func isThePick() throws {
        let picked = try Self.picked()
        #expect("\(Self.edition.shape)" == "wideRectangle")
        #expect(Self.edition.cord == Color(hexString: try #require(picked["cord_hex"] as? String)))
        #expect(Self.edition.twill == Color(hexString: try #require(picked["twill_hex"] as? String)))
        #expect(abs(Self.edition.aspect - 1.42) < 0.001)
        #expect(!Self.edition.isCanvas, "a twill, not Uncharted's canvas")
        #expect(Self.edition != PatchEdition.of(setID: nil), "without an edition of its own it would draw as Uncharted")
    }

    /// How much of two editions' silhouettes is shared when both are drawn at one width about one centre, as two boards'
    /// tiles are: the overlap over the union.
    static func overlap(_ a: PatchEdition, _ b: PatchEdition) -> Double {
        func outline(_ edition: PatchEdition) -> Path {
            let height = 100 / edition.aspect
            return PatchOutline(shape: edition.shape).path(in: CGRect(x: -50, y: -height / 2, width: 100, height: height))
        }
        let (first, second) = (outline(a), outline(b))
        var (both, either) = (0, 0)
        for y in stride(from: -80.0, through: 80, by: 1) {
            for x in stride(from: -60.0, through: 60, by: 1) {
                let point = CGPoint(x: x, y: y)
                let (inFirst, inSecond) = (first.contains(point), second.contains(point))
                if inFirst && inSecond { both += 1 }
                if inFirst || inSecond { either += 1 }
            }
        }
        return Double(both) / Double(max(either, 1))
    }

    @Test("on a board it can't be taken for another edition: it is further from each of the eight than the nearest two of them are from each other")
    func isItsOwnShape() {
        let eight = EditionTintTests.setIDs.filter { $0 != Self.setID }.map(PatchEdition.of(setID:))
        #expect(eight.count == 8)
        var nearestOfTheEight = 0.0
        for (index, one) in eight.enumerated() {
            for other in eight.dropFirst(index + 1) { nearestOfTheEight = max(nearestOfTheEight, Self.overlap(one, other)) }
        }
        let nearest = eight.map { Self.overlap(Self.edition, $0) }.max() ?? 1
        #expect(nearest < nearestOfTheEight, "its nearest shares \(nearest) of the two; the eight's nearest pair \(nearestOfTheEight)")
        let borough = Self.overlap(Self.edition, PatchEdition.of(setID: "us-ny-nyc"))
        #expect(borough < 0.75, "Borough's rounded square is the shape it could be taken for: \(borough)")
        #expect(Self.edition.aspect > 1.25, "the only patch much wider than tall")
        #expect(eight.allSatisfy { $0.aspect < 1.15 })
    }

    // MARK: - Where it is drawn

    /// Where the cord's colour is in a picture, and how much of that rectangle is the twill's.
    static func cloth(in image: UIImage) throws -> (cord: CGRect, twillShare: Double) {
        let (bytes, width, height) = try ShareCardTests.rgba(image)
        // The twill gets more room than the cord: its rib is printed over it. Uncharted's canvas is 0.27 from it, Borough's cream 0.38.
        func near(_ index: Int, _ colour: UIColor, within limit: CGFloat = 0.12) -> Bool {
            guard bytes[index + 3] > 250 else { return false }
            let pixel = UIColor(red: CGFloat(bytes[index]) / 255, green: CGFloat(bytes[index + 1]) / 255, blue: CGFloat(bytes[index + 2]) / 255, alpha: 1)
            return TokenPairingTests.distance(pixel, colour) < limit
        }
        let (cord, twill) = (UIColor(edition.cord), UIColor(edition.twill))
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for y in 0..<height {
            for x in 0..<width where near((y * width + x) * 4, cord) {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        guard maxX >= 0 else { return (.zero, 0) }
        var cloth = 0
        for y in minY...maxY {
            for x in minX...maxX where near((y * width + x) * 4, twill, within: 0.2) { cloth += 1 }
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return (box, Double(cloth) / Double(box.width * box.height))
    }

    /// `view` in a phone-sized window, as drawn, at one pixel a point.
    static func picture(of view: some View, size: CGSize) async throws -> UIImage {
        let host = UIHostingController(rootView: view.environment(\.colorScheme, .light))
        host.overrideUserInterfaceStyle = .light
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1.5))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    static func expectContinental(_ image: UIImage, _ surface: String, minimumWidth: CGFloat, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let drawn = try cloth(in: image)
        #expect(drawn.cord.width >= minimumWidth, "\(surface): golden cord \(drawn.cord)", sourceLocation: sourceLocation)
        // The cord is stroked on the outline, so its outside is half a cord wider and taller than the patch.
        #expect(abs(drawn.cord.width / max(drawn.cord.height, 1) - 1.42) < 0.06, "\(surface): wide, 1.42 to 1: \(drawn.cord)", sourceLocation: sourceLocation)
        #expect(drawn.twillShare > 0.3, "\(surface): lavender-grey twill inside the cord: \(drawn.twillShare)", sourceLocation: sourceLocation)
    }

    @Test("a robin found in the middle of the continent is a Continental patch on its board: the wide blank in golden cord and lavender twill, read as Continental edition")
    func onTheBoard() async throws {
        let (harness, store, patch) = try Self.found()
        #expect(patch.placement.setID == Self.setID)
        let board = PatchBoard(patches: store.collection.patches(in: Self.setID)).padding(16).environment(store)
        let image = try await Self.picture(of: harness.hosted(ScrollView { board }.background(Color.white), typeSize: .large), size: CGSize(width: 402, height: 500))
        try Self.expectContinental(image, "the board", minimumWidth: 90)

        let labels = try await Screens.walk(ScrollView { board }, harness: harness) { $0.contains { $0.contains("edition patch") } }
        #expect(labels.contains { $0.hasPrefix("American Robin, Continental edition patch, seen once, sewn ") }, "\(labels)")
    }

    @Test("its page shows the same patch large, and VoiceOver reads its edition in the patch's sentence and in the words under it")
    func onItsPage() async throws {
        let (harness, store, patch) = try Self.found()
        let page = PatchDetailView(key: patch.id).environment(store)
        let image = try await Self.picture(of: harness.hosted(page, typeSize: .large), size: CGSize(width: 402, height: 874))
        try Self.expectContinental(image, "the patch's page", minimumWidth: 250)

        let labels = try await Screens.walk(page, harness: harness) { $0.contains("Turn over") && $0.contains { $0.contains("edition patch") } }
        Screens.expectClean(labels, screen: "A Continental patch's page")
        #expect(labels.contains { $0.hasPrefix("American Robin, Continental edition patch, seen once, sewn ") }, "\(labels)")
        #expect(labels.contains("Continental edition, No. 002"), "the words under the patch: \(labels)")
    }

    @Test("its paper card is headed Continental edition, with its number in North America")
    func onItsPaperCard() async throws {
        let (harness, store, patch) = try Self.found()
        let labels = try await Screens.walk(PatchDetailView(key: patch.id, startsTurned: true).environment(store), harness: harness) { labels in
            labels.contains("Turn back") && labels.contains { $0.hasPrefix("1 sighting here") }
        }
        Screens.expectClean(labels, screen: "A Continental patch's paper card")
        #expect(labels.contains("Continental edition, number 2 of 2 in North America"), "\(labels)")
        #expect(labels.contains { $0.hasPrefix("1 sighting here, sewn ") }, "\(labels)")
    }

    // MARK: - Outside the app

    @Test("the widget's picture of it is the wide patch, smaller than the square the widget budgets for")
    func inTheWidget() throws {
        let image = try #require(FlatPatch.render(loaded: nil, edition: Self.edition, tag: "American Robin", width: LatestPatchPublisher.patchWidth, scale: LatestPatchPublisher.patchScale))
        #expect(abs(image.size.width - (LatestPatchPublisher.patchWidth + FlatPatch.room * 2)) < 1)
        #expect(abs(image.size.height - (LatestPatchPublisher.patchWidth / 1.42 + FlatPatch.room * 2)) < 1, "as tall as the patch, not as its width: \(image.size)")
        let drawn = try Self.cloth(in: image)
        #expect(abs(drawn.cord.width / max(drawn.cord.height, 1) - 1.42) < 0.06, "\(drawn.cord)")
        #expect(drawn.twillShare > 0.3)
    }

    @Test("the widget and the Live Activity take its tint, light and dark, and not the aqua of a set the app doesn't know")
    func glanceTint() {
        for scheme in [ColorScheme.light, .dark] {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            let traits = UITraitCollection { $0.userInterfaceStyle = style }
            let widget = UIColor(GlanceInk.tint(setID: Self.setID, scheme, .standard))
            #expect(TokenPairingTests.distance(widget, UIColor(PatchEdition.tint(setID: Self.setID)).resolvedColor(with: traits)) < 0.01, "\(scheme)")
            #expect(TokenPairingTests.distance(widget, UIColor(GlanceInk.tint(setID: "somewhere-new", scheme, .standard))) > 0.2, "\(scheme)")
        }
        #expect(PatchEdition.tint(setID: Self.setID) == Color("EditionContinental"))
    }
}
