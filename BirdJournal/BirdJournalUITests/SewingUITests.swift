import XCTest

/// Issue #135 (guide pages 5 and 14): real taps through the ceremony, on a phone run in Griffith Park so an add sews a patch
/// with a painting. A first add stitches and reveals, a repeat ticks the count, and neither comes back when the patch is
/// reopened. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class SewingUITests: XCTestCase {
    private static let name = "House Finch"

    @MainActor
    private func launch(_ extra: [String]) throws -> XCUIApplication {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
        guard FileManager.default.fileExists(atPath: clip.path(percentEncoded: false)) else {
            throw XCTSkip("no example soundscape at \(clip.path(percentEncoded: false))")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES",
            "-autoPhoneListening", clip.path(percentEncoded: false), "-autoLocation", "griffith", "-autoScreen", "listening",
        ] + extra
        app.launch()
        return app
    }

    /// Reviews the House Finch and taps its add button.
    @MainActor
    private func add(_ app: XCUIApplication, button: String, row: String = "Review \(SewingUITests.name)") {
        let review = app.buttons[row]
        XCTAssertTrue(review.waitForExistence(timeout: 90), "no \(row); screen: \(app.debugDescription.prefix(3000))")
        review.tap()
        let add = app.buttons[button]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no \(button); screen: \(app.debugDescription.prefix(3000))")
        add.tap()
    }

    @MainActor
    func testAFirstAddStitchesAndRevealsARepeatTicksTheCountAndNeitherReplays() throws {
        // A slow stitch-in, so it can be caught part way and tapped through.
        let app = try launch(["-stitchInSeconds", "60"])
        add(app, button: "Add and sew patch")

        let stitching = app.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "no stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your \(Self.name) patch")
        let reveal = app.staticTexts["Your first \(Self.name) in Los Angeles"]
        XCTAssertFalse(reveal.exists, "the reveal waits for the stitching")

        stitching.tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "tapping didn't finish it; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.exists)
        XCTAssertTrue(app.staticTexts["New patch · Citrus edition"].exists, "screen: \(app.debugDescription.prefix(4000))")
        let keepListening = app.buttons["Keep listening"]
        XCTAssertTrue(keepListening.exists, "the primary action during a run")
        keepListening.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "the reveal closed")

        // The same bird again: nothing to stitch, and its count.
        add(app, button: "Add another sighting", row: "Added. Review \(Self.name)")
        XCTAssertTrue(app.staticTexts["Seen again · Citrus edition"].waitForExistence(timeout: 10), "no seen-again page; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.exists, "a repeat stitches nothing")
        XCTAssertFalse(reveal.exists, "a repeat is not a new patch")
        let count = app.descendants(matching: .any)["seen-again-line"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "Seen 2 times in Los Angeles")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "seen-again-sighting").count, 2, "the latest sightings; screen: \(app.debugDescription.prefix(4000))")
        keepListening.tap()
        XCTAssertFalse(count.waitForExistence(timeout: 2), "the page closed")

        // Reopening the patch shows the patch: neither comes back.
        app.tabBars.buttons["Collection"].tap()
        let patch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'seen 2 times'", Self.name)).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 10), "no patch seen twice; screen: \(app.debugDescription.prefix(4000))")
        patch.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch didn't open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.waitForExistence(timeout: 2), "reopening a patch never stitches it again")
        XCTAssertFalse(reveal.exists, "or reveals it again")
        XCTAssertFalse(app.staticTexts["Seen again · Citrus edition"].exists, "or ticks its count")
    }

    @MainActor
    func testTheStitchInFinishesOnItsOwnInAboutFourSeconds() throws {
        let app = try launch([])
        add(app, button: "Add and sew patch")
        let reveal = app.staticTexts["Your first \(Self.name) in Los Angeles"]
        let began = Date.now
        XCTAssertTrue(reveal.waitForExistence(timeout: 15), "the stitch-in didn't end; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertGreaterThan(Date.now.timeIntervalSince(began), 2, "it took its time")
        XCTAssertFalse(app.buttons["stitch-in"].exists)
    }

    @MainActor
    func testReduceMotionShowsTheFinishedPatchAtOnce() throws {
        let app = try launch(["-reduceMotion", "YES", "-stitchInSeconds", "60"])
        add(app, button: "Add and sew patch")
        XCTAssertTrue(app.staticTexts["Your first \(Self.name) in Los Angeles"].waitForExistence(timeout: 10), "no finished patch under a 60 s stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "no stitching")
    }
}
