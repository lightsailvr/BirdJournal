import UIKit
import XCTest

/// Issue #138, guide page 15: every state a patch screen can be in, with real taps on the running app. Each new thing you can
/// tap is tapped: a blank, where its paper tag hangs, a silhouette row, and the ways on from an empty collection and an unfound bird.
final class PatchStatesUITests: XCTestCase {
    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES"] + arguments
        app.launch()
        return app
    }

    private let seeded = ["-seedJournal", "YES"]

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // MARK: - Empty collection

    @MainActor
    func testAnEmptyCollectionSaysTheFirstPatchIsABirdAwayAndGoesToListen() throws {
        let app = launch(["-autoScreen", "journal"])
        XCTAssertTrue(app.staticTexts["Your first patch is a bird away."].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["board-patch"].exists, "no patch on an empty board")
        element(app, "empty-start-listening").tap()
        XCTAssertTrue(app.tabBars.buttons["Listen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Listen"].isSelected, "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAnEmptyCollectionHasAPathToTheAtlas() throws {
        let app = launch(["-autoScreen", "journal"])
        XCTAssertTrue(element(app, "empty-open-atlas").waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        element(app, "empty-open-atlas").tap()
        let atlas = app.tabBars.buttons["Atlas"]
        XCTAssertTrue(atlas.waitForExistence(timeout: 5))
        XCTAssertTrue(atlas.isSelected, "screen: \(app.debugDescription.prefix(3000))")
    }

    // MARK: - Not yet found

    @MainActor
    func testANotYetFoundRowHasItsNumberAndNameAndOpensTheProfile() throws {
        let app = launch(seeded + ["-autoScreen", "set"])
        let row = app.buttons.matching(identifier: "set-species-silhouette").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(row.label, "001, Canada Goose, still out there")
        XCTAssertTrue(app.staticTexts["157 still out there"].exists, "one count, once, as a heading; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["Not yet found here"].exists)
        row.tap()
        XCTAssertTrue(app.staticTexts["Canada Goose"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Branta canadensis"].exists, "the Atlas profile")
    }

    @MainActor
    func testTheBirdsPageSaysNoSightingsWithItsNumberAndWaysOn() throws {
        let app = launch(seeded + ["-autoScreen", "set"])
        let row = app.buttons.matching(identifier: "set-species-silhouette").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        let yours = element(app, "profile-your-cards")
        XCTAssertTrue(yours.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        yours.tap()
        XCTAssertTrue(app.staticTexts["No sightings of Canada Goose yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(element(app, "species-set-number").exists, "its number")
        XCTAssertEqual(element(app, "species-set-number").label, "Number 1 of 160 in Los Angeles")
        XCTAssertFalse(app.buttons["board-patch"].exists, "no patch for a bird you haven't found")
        app.buttons["Open in Atlas"].tap()
        XCTAssertTrue(app.staticTexts["Branta canadensis"].waitForExistence(timeout: 10), "its Atlas profile: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAnUnfoundBirdsStartListeningGoesToListen() throws {
        let app = launch(seeded + ["-autoCardSpecies", "Branta canadensis", "-autoScreen", "species"])
        let start = app.buttons["Start listening"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        start.tap()
        let listen = app.tabBars.buttons["Listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertTrue(listen.isSelected, "screen: \(app.debugDescription.prefix(3000))")
    }

    // MARK: - Without its painting

    @MainActor
    func testATaggedBlankOpensItsPageAndTurnsOverToACompleteCard() throws {
        let app = launch(seeded + ["-fakePatchArt", "missing", "-autoScreen", "cards"])
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Black Phoebe, Citrus edition patch'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(tile.label.contains("art on its way"), tile.label)
        // Where the paper tag hangs: the tag takes no touch of its own.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        let face = element(app, "patch-face")
        XCTAssertTrue(face.waitForExistence(timeout: 10), "the tile opened its page: \(app.debugDescription.prefix(3000))")
        // The blank turns over like any patch, from the tag too.
        face.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32)).tap()
        XCTAssertTrue(element(app, "card-name").waitForExistence(timeout: 5), "the card, complete: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(element(app, "card-history").exists)
        XCTAssertFalse(element(app, "card-art-credit").exists, "no painting to credit")
    }

    @MainActor
    func testABlankBeingSewnSaysSoAndOpensItsPage() throws {
        let app = launch(seeded + ["-fakePatchArt", "sewing", "-autoScreen", "cards"])
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Black Phoebe, Citrus edition patch' AND label ENDSWITH ', art on its way'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        tile.tap()
        let face = element(app, "patch-face")
        XCTAssertTrue(face.waitForExistence(timeout: 10))
        XCTAssertTrue(face.label.hasSuffix(", art on its way"), face.label)
    }

    @MainActor
    func testANewPatchWithoutItsPaintingGoesStraightToTheFinishedPage() throws {
        let app = launch(seeded + ["-fakePatchArt", "missing", "-autoScreen", "reveal", "-autoCardSpecies", "Sayornis nigricans"])
        XCTAssertTrue(element(app, "revealed-patch").waitForExistence(timeout: 15), "no stitching without a painting: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Done"].exists, "the page is the same however the art stands")
    }

    // MARK: - Uncharted

    @MainActor
    func testUnchartedPatchesAreOnTheirBoardAndTheCardSaysOutsideEverySet() throws {
        let app = launch(seeded + ["-autoBoard", "uncharted", "-autoScreen", "cards"])
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH \"Anna's Hummingbird, Uncharted patch\"")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["2 outside every set"].exists, "screen: \(app.debugDescription.prefix(3000))")
        tile.tap()
        let flip = element(app, "card-flip")
        XCTAssertTrue(flip.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        flip.tap()
        let heading = element(app, "card-heading")
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertEqual(heading.label, "Uncharted, outside every set")
    }

    // MARK: - Reduce Motion

    /// The patch's pixels on its page, with the light wherever `-patchLight` puts it (a launch stands in for a tilt: a
    /// process of its own, so the flags can't reach another suite's tests).
    @MainActor
    private func patchPixels(_ flags: [String]) throws -> (bytes: [UInt8], image: XCUIScreenshot) {
        let app = launch(seeded + ["-autoScreen", "card", "-autoCardSpecies", "Sayornis nigricans"] + flags)
        let face = element(app, "patch-face")
        XCTAssertTrue(face.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        // Past the page's push and the patch's decode.
        Thread.sleep(forTimeInterval: 3)
        let shot = face.screenshot()
        let cg = try XCTUnwrap(shot.image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        app.terminate()
        return (bytes, shot)
    }

    private func meanChange(_ first: [UInt8], _ second: [UInt8]) -> Double {
        Double(zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(first.count, 1))
    }

    @MainActor
    func testReduceMotionFixesTheLight() throws {
        let tilted = ["-patchLight", "l0.5,0.5"]
        let rest = try patchPixels([])
        let moved = try patchPixels(tilted)
        let change = meanChange(rest.bytes, moved.bytes)
        XCTAssertGreaterThan(change, 1, "the control: without Reduce Motion the light moves the patch")
        let still = try patchPixels(["-reduceMotion", "YES"])
        let stillMoved = try patchPixels(["-reduceMotion", "YES"] + tilted)
        XCTAssertLessThan(meanChange(still.bytes, stillMoved.bytes), 0.05, "with Reduce Motion the light stays where it rests")
        add(XCTAttachment(screenshot: moved.image))
    }

    // MARK: - As 1.0: truthful and recoverable, never stitched

    @MainActor
    func testGlassesDisconnectedSaysSoOnListen() throws {
        let app = launch(seeded + ["-listeningSource", "glasses", "-fakeGlasses", "notConnected", "-autoScreen", "listen"])
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'not connected'")).firstMatch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testGuildsOfflineSaysSoAndOffersTryAgain() throws {
        let app = launch(seeded + ["-fakeAccount", "signedIn", "-fakeCircles", "offline", "-autoScreen", "circles"])
        XCTAssertTrue(app.staticTexts["Can't reach your Guilds"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Try again"].exists)
    }

    @MainActor
    func testTheBoardWorksOfflineWithTheIndexUnreachable() throws {
        let app = launch(seeded + ["-packIndexURL", "http://127.0.0.1:9/index.json", "-autoScreen", "cards"])
        let tile = app.buttons["board-patch"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        tile.tap()
        XCTAssertTrue(element(app, "patch-face").waitForExistence(timeout: 10), "a patch needs no network")
    }

    @MainActor
    func testASightingWithNoLocationExplainsItsRarityInPlainWords() throws {
        let app = launch(seeded + ["-autoScreen", "sighting", "-autoCardSpecies", "Turdus merula"])
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        let opens = app.buttons["Rarity"]
        for _ in 0..<8 where !opens.isHittable { app.swipeUp() }
        opens.tap()
        let rarity = app.staticTexts["Rarity unavailable for this place and season. No location was saved with this sighting, and rarity is never guessed."]
        XCTAssertTrue(rarity.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
    }
}
