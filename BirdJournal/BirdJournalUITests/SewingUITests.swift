import XCTest

/// Issue #135 (guide pages 5 and 14): real taps through the ceremony, on a phone run in Griffith Park so an add sews a patch
/// with a painting. A first add stitches and reveals, a repeat only ticks the count, and neither comes back when the patch is
/// reopened. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class SewingUITests: XCTestCase {
    private static let name = "House Finch"

    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    @MainActor
    private func launch(_ extra: [String]) throws -> XCUIApplication {
        let clip = try Self.clip()
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES",
            "-autoPhoneListening", clip, "-autoLocation", "griffith", "-autoScreen", "listening",
        ] + extra
        app.launch()
        return app
    }

    /// Reviews the House Finch and taps its add button. The live list re-sorts as birds call, so a tap can land on the row
    /// that has just moved under it: that bird's sheet is closed and the row tried again.
    @MainActor
    private func add(_ app: XCUIApplication, button: String, row: String = "Review \(SewingUITests.name)") {
        let review = app.buttons[row]
        let add = app.buttons[button]
        for _ in 0..<5 {
            XCTAssertTrue(review.waitForExistence(timeout: 90), "no \(row); screen: \(app.debugDescription.prefix(3000))")
            review.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "no sheet; screen: \(app.debugDescription.prefix(3000))")
            if app.staticTexts[Self.name].exists, add.waitForExistence(timeout: 10) {
                add.tap()
                return
            }
            app.buttons["Close"].tap()
        }
        XCTFail("never reached \(button) for \(Self.name); screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAFirstAddStitchesAndRevealsARepeatTicksTheCountAndNeitherReplays() throws {
        // A slow stitch-in, so it can be caught part way and tapped through.
        let app = try launch(["-stitchInSeconds", "60"])
        add(app, button: "Add and sew patch")

        let stitching = app.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "no stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your \(Self.name) patch")
        // The page's own line: "Your first …" is also the acknowledgment's, in the toast under the page.
        let reveal = app.staticTexts["New patch, Citrus edition"]
        XCTAssertFalse(reveal.exists, "the reveal waits for the stitching")

        stitching.tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "tapping didn't finish it; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.exists)
        XCTAssertTrue(app.staticTexts["Your first \(Self.name) in Los Angeles"].exists, "screen: \(app.debugDescription.prefix(4000))")
        let keepListening = app.buttons["Keep listening"]
        XCTAssertTrue(keepListening.exists, "the primary action during a run")
        keepListening.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "the reveal closed")

        // The same bird again: the sighting and its count, with no page and nothing to tap (the maintainer, 2026-11-04).
        add(app, button: "Add another sighting", row: "Added. Review \(Self.name)")
        let seenAgain = app.staticTexts["Seen again, 2 times in Los Angeles"]
        XCTAssertTrue(seenAgain.waitForExistence(timeout: 10), "no count; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.exists, "a repeat stitches nothing")
        XCTAssertFalse(reveal.exists, "a repeat is not a new patch")
        XCTAssertFalse(keepListening.exists, "and asks for no tap")
        let row = app.buttons["Added. Review \(Self.name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the run's list is right there; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(row.isHittable, "nothing covers it")
        XCTAssertTrue(app.tabBars.buttons["Collection"].isHittable, "nothing covers the tabs")

        // Reopening the patch shows the patch: neither comes back.
        app.tabBars.buttons["Collection"].tap()
        let patch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'seen 2 times'", Self.name)).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 10), "no patch seen twice; screen: \(app.debugDescription.prefix(4000))")
        patch.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch didn't open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(stitching.waitForExistence(timeout: 2), "reopening a patch never stitches it again")
        XCTAssertFalse(reveal.exists, "or reveals it again")
        XCTAssertFalse(seenAgain.exists, "or says its count again")
    }

    @MainActor
    func testTheStitchInFinishesOnItsOwn() throws {
        let app = try launch([])
        add(app, button: "Add and sew patch")
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "the stitch-in didn't end; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists)
    }

    @MainActor
    func testReduceMotionShowsTheFinishedPatchAndTheNewCountAtOnce() throws {
        let app = try launch(["-reduceMotion", "YES", "-stitchInSeconds", "60"])
        add(app, button: "Add and sew patch")
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 10), "no finished patch under a 60 s stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "no stitching")
        app.buttons["Keep listening"].tap()

        add(app, button: "Add another sighting", row: "Added. Review \(Self.name)")
        XCTAssertTrue(app.staticTexts["Seen again, 2 times in Los Angeles"].waitForExistence(timeout: 10), "no count; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "no page")
    }

    // The glasses are about hearing and capturing; the celebration of the patch is on the phone once the run is over (the
    // maintainer, 2026-11-04). A real run on Mock Device Kit with the clip standing in for its stream, in an album on disk so
    // a relaunch finds it.

    @MainActor
    private func launchGlassesRun(adding birds: String, album: String, extra: [String] = []) throws -> XCUIApplication {
        let clip = try Self.clip()
        let app = XCUIApplication()
        app.launchArguments = [
            "-albumFile", album, "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))",  // the port is the Mac's, and agents test side by side
            "-autoGlassesListening", clip, "-autoLocation", "griffith", "-autoScreen", "glasses-run", "-autoLensAdd", birds,
        ] + extra
        app.launch()
        return app
    }

    /// The app started again by hand, over the same album, with no run.
    @MainActor
    private func relaunch(album: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-albumFile", album, "-collectionIntroShown", "YES", "-autoLocation", "griffith"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func waitForLensAdd(of bird: String, _ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Added. Review \(bird)"].waitForExistence(timeout: 120), "the lens didn't add \(bird); screen: \(app.debugDescription.prefix(4000))")
    }

    /// A new album for each test: a bird already in it wouldn't sew anything.
    private static func album() -> String { "sewing-\(UUID().uuidString)" }

    @MainActor
    func testAGlassesAddShowsNothingUntilTheRunEndsThenStitchesOnceAndNotAgainOnRelaunch() throws {
        let album = Self.album()
        let app = try launchGlassesRun(adding: Self.name, album: album, extra: ["-stitchInSeconds", "60"])
        waitForLensAdd(of: Self.name, app)

        let stitching = app.buttons["stitch-in"]
        let reveal = app.staticTexts["New patch, Citrus edition"]
        XCTAssertFalse(stitching.waitForExistence(timeout: 4), "nothing on the phone mid-run; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(reveal.exists, "nothing on the phone mid-run")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "nothing on the phone mid-run")
        XCTAssertFalse(app.staticTexts["Your first \(Self.name) in Los Angeles"].exists, "not even the toast: the lens said it")

        app.buttons["Stop listening"].tap()
        XCTAssertTrue(stitching.waitForExistence(timeout: 15), "no stitch-in when the run ended; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your \(Self.name) patch")
        stitching.tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "tapping didn't finish it; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["Next patch"].exists, "this was the only one")
        XCTAssertFalse(app.buttons["Undo"].exists, "no Undo long after the add")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists, "the run is over; screen: \(app.debugDescription.prefix(4000))")
        done.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "the reveal closed")

        let again = relaunch(album: album, extra: ["-stitchInSeconds", "60"])
        XCTAssertFalse(again.buttons["stitch-in"].waitForExistence(timeout: 6), "it plays once; screen: \(again.debugDescription.prefix(4000))")
        XCTAssertFalse(again.staticTexts["New patch, Citrus edition"].exists, "it plays once")
        again.tabBars.buttons["Collection"].tap()
        let patch = again.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'seen once'", Self.name)).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 10), "the patch is there all the same; screen: \(again.debugDescription.prefix(4000))")
    }

    @MainActor
    func testKilledMidRunTheCeremoniesWaitForTheNextLaunchAndTheRestCanBeSkipped() throws {
        let album = Self.album()
        let app = try launchGlassesRun(adding: "\(Self.name),Dark-eyed Junco", album: album)
        waitForLensAdd(of: "Dark-eyed Junco", app)

        let next = relaunch(album: album, extra: ["-stitchInSeconds", "60"])
        let stitching = next.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 15), "no ceremony after the kill; screen: \(next.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your \(Self.name) patch", "the order sewn")
        stitching.tap()
        let skip = next.buttons["Skip the rest, 1 more"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "no way to skip the rest; screen: \(next.debugDescription.prefix(4000))")
        XCTAssertTrue(next.buttons["Next patch"].exists)
        XCTAssertFalse(next.buttons["See it in my collection"].exists, "the rest first")
        skip.tap()
        XCTAssertFalse(next.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 2), "the page closed")
        XCTAssertFalse(stitching.exists, "and the junco's never started")

        let third = relaunch(album: album, extra: ["-stitchInSeconds", "60"])
        XCTAssertFalse(third.buttons["stitch-in"].waitForExistence(timeout: 6), "skipped stays skipped; screen: \(third.debugDescription.prefix(4000))")
    }

    @MainActor
    func testUnderReduceMotionSeveralFromTheGlassesGoFinishedPageToFinishedPage() throws {
        let app = try launchGlassesRun(adding: "\(Self.name),Dark-eyed Junco", album: Self.album(), extra: ["-reduceMotion", "YES"])
        waitForLensAdd(of: "Dark-eyed Junco", app)
        app.buttons["Stop listening"].tap()

        let nextPatch = app.buttons["Next patch"]
        XCTAssertTrue(nextPatch.waitForExistence(timeout: 15), "no finished page; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "no stitching")
        XCTAssertTrue(app.staticTexts["Your first \(Self.name) in Los Angeles"].exists, "the order sewn; screen: \(app.debugDescription.prefix(4000))")
        nextPatch.tap()
        XCTAssertTrue(app.staticTexts["Your first Dark-eyed Junco in Los Angeles"].waitForExistence(timeout: 5), "no second patch; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(nextPatch.exists, "the last one")
        XCTAssertTrue(app.buttons["See it in my collection"].exists, "the last one offers the collection")
        XCTAssertFalse(app.buttons["Skip the rest, 1 more"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 2), "nothing more; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testStoppingFromAnotherTabStillPlaysTheCeremony() throws {
        let app = try launchGlassesRun(adding: Self.name, album: Self.album(), extra: ["-reduceMotion", "YES"])
        waitForLensAdd(of: Self.name, app)
        app.tabBars.buttons["Collection"].tap()
        let stop = app.buttons["Stop listening"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "no listening strip; screen: \(app.debugDescription.prefix(4000))")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Your first \(Self.name) in Los Angeles"].waitForExistence(timeout: 15), "the ceremony didn't play; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testARunThatEndsWithTheAppInTheBackgroundWaitsForTheForeground() throws {
        // Long enough to be still going on the way back, if it waited; over well before then, if it started in the background.
        let app = try launchGlassesRun(adding: Self.name, album: Self.album(), extra: ["-stitchInSeconds", "8", "-autoLensBackInBackground", "YES"])
        waitForLensAdd(of: Self.name, app)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5), "still in front")
        Thread.sleep(forTimeInterval: 12)
        app.activate()

        XCTAssertTrue(app.buttons["stitch-in"].waitForExistence(timeout: 6), "it didn't wait for the foreground; screen: \(app.debugDescription.prefix(4000))")
    }
}
