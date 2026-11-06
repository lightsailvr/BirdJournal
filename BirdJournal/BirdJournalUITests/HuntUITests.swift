import XCTest

/// Issue #150 (L1, L2, V2, A2): real taps on a phone run over the soundscape, in Griffith Park so an add sews a Los Angeles
/// patch with a painting. Sew it and Add go straight to the add, with the reveal or the count and Undo; the rest of the row opens
/// the review. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class HuntUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    @MainActor
    private func launchRun(location: String = "griffith", _ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", location, "-autoScreen", "listening",
        ] + extra
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, beginning prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testSewItOnARowStitchesRevealsAndUndoTakesItBack() throws {
        let app = try launchRun(["-stitchInSeconds", "60"])
        let sew = button(app, beginning: "Sew it, ")
        XCTAssertTrue(sew.waitForExistence(timeout: 90), "no Sew it; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'waiting'")).firstMatch.exists, "the summary leads with what's waiting; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Possible matches. Add the birds you recognize."].exists)
        XCTAssertFalse(app.buttons["Review House Finch"].exists, "no Review on a bird a pack describes")
        sew.tap()

        // The list can reorder under a tap: the stitch-in says which bird it was.
        let stitching = app.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "no stitch-in; screen: \(app.debugDescription.prefix(4000))")
        let name = stitching.label.replacingOccurrences(of: "Sewing your ", with: "").replacingOccurrences(of: " patch", with: "")
        stitching.tap()
        let reveal = app.staticTexts["New patch, Citrus edition"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "no reveal; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first \(name) in Los Angeles"].exists, "screen: \(app.debugDescription.prefix(4000))")

        let undo = app.buttons["Undo adding \(name)"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo; screen: \(app.debugDescription.prefix(4000))")
        undo.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "Undo closes the reveal")
        XCTAssertTrue(app.buttons["Sew it, \(name)"].waitForExistence(timeout: 10), "the bird is new again; screen: \(app.debugDescription.prefix(4000))")

        // Sewn and kept, the row shows it.
        app.buttons["Sew it, \(name)"].tap()
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        let sewnName = stitching.label.replacingOccurrences(of: "Sewing your ", with: "").replacingOccurrences(of: " patch", with: "")
        stitching.tap()
        let keepListening = app.buttons["Keep listening"]
        XCTAssertTrue(keepListening.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        keepListening.tap()
        XCTAssertTrue(app.buttons["Added. Review \(sewnName)"].waitForExistence(timeout: 10), "patch and check; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(button(app, beginning: "\(sewnName), added, you have this patch").exists, "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testAddOnARowWithAPatchTicksTheCountAndUndoTakesItBack() throws {
        let app = try launchRun(["-seedJournal", "YES", "-stitchInSeconds", "60"])
        let add = app.buttons["Add House Finch"]
        XCTAssertTrue(add.waitForExistence(timeout: 90), "no Add on the seeded bird; screen: \(app.debugDescription.prefix(3000))")
        add.tap()

        // The list can reorder under a tap; a bird with no patch would stitch instead, and that's another test.
        let seenAgain = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Seen again'")).firstMatch
        XCTAssertTrue(seenAgain.waitForExistence(timeout: 10), "no count; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "a repeat stitches nothing")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "and opens no page")
        XCTAssertTrue(app.buttons["Added. Review House Finch"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")

        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5), "it can be added again; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(seenAgain.exists, "the count went with it")
    }

    @MainActor
    func testTappingARowOpensTheReviewAndAddsNothing() throws {
        let app = try launchRun(["-stitchInSeconds", "60"])
        let row = button(app, beginning: "House Finch, ")
        XCTAssertTrue(row.waitForExistence(timeout: 90), "no row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "no review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.segmentedControls["review-method"].waitForExistence(timeout: 5), "Heard or Seen is on the review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "nothing added")
        app.buttons["Close"].tap()
        XCTAssertTrue(button(app, beginning: "Sew it, ").waitForExistence(timeout: 10), "still waiting; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTheProfileOfABirdYouveFoundLeadsWithItsPatchWhichOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedJournal", "YES", "-autoCardSpecies", "Sayornis nigricans", "-autoScreen", "profile"]
        app.launch()
        let patch = app.buttons["profile-patch"].firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 15), "no patch; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(patch.isHittable)
        XCTAssertTrue(patch.label.hasPrefix("Black Phoebe, Citrus edition patch"), patch.label)
        let name = app.staticTexts["Black Phoebe"].firstMatch
        XCTAssertTrue(name.exists)
        XCTAssertLessThan(patch.frame.minY, name.frame.minY, "the patch comes first")
        patch.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch didn't open; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTheReviewOfABirdYouveFoundLeadsWithThePhotoNotThePatch() throws {
        let app = try launchRun(["-seedJournal", "YES"])
        let row = button(app, beginning: "House Finch, ")
        XCTAssertTrue(row.waitForExistence(timeout: 90), "no row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "no review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["profile-patch"].waitForExistence(timeout: 2), "the photo comes first; screen: \(app.debugDescription.prefix(3000))")
    }
}
