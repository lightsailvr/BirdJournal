import XCTest

/// Issue #186 (of #185): real taps from "Capture a sighting" through the camera and "Name this bird" to the row under "Seen
/// this run", on a run in Griffith Park that holds still (`-fakeRunBirds`). The simulator has no camera, so a stand-in is
/// behind the button (`-fakeCamera`). Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class CaptureUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// A phone run that has heard a House Finch, with nothing in the album. Reduce Motion, so a new patch's page is the
    /// finished patch at once, and the acknowledgment held long enough to reach its Undo.
    @MainActor
    private func launchRun(camera: String = "ready", _ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeRunBirds", "Haemorhous mexicanus_House Finch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
            "-fakeCamera", camera, "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Opens the camera from the run's page and takes the photo: "Name this bird" is up when this returns.
    @MainActor
    private func capture(_ app: XCUIApplication) {
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 90), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(capture.label, "Capture a sighting")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: capture)
        wait(for: [enabled], timeout: 60)
        capture.tap()
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "no camera; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(shutter.label, "Take photo")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: shutter)
        wait(for: [ready], timeout: 15)
        shutter.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    private func search(_ app: XCUIApplication, for text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field; screen: \(app.debugDescription.prefix(3000))")
        field.tap()
        // Return puts the keyboard away, so the results and the pinned add are all in reach.
        field.typeText(text + "\n")
    }

    @MainActor
    func testCaptureNameAndSeeTheBirdUnderSeenThisRunThenUndo() throws {
        let app = try launchRun()
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 90), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["Seen this run"].exists, "nothing seen yet")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: capture)
        wait(for: [enabled], timeout: 60)
        capture.tap()

        // The camera, in the app: a way out, the run still listening with its clock moving, and the shutter.
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "no camera; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Close camera"].exists)
        let pill = element(app, "capture-listening")
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the camera doesn't say the run is listening; screen: \(app.debugDescription.prefix(3000))")
        let before = pill.label
        XCTAssertTrue(before.hasPrefix("Still listening, "), before)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertNotEqual(pill.label, before, "the run's clock keeps going behind the camera")
        XCTAssertTrue(pill.label.hasPrefix("Still listening, "), pill.label)
        shutter.tap()

        // Name this bird: the photo, the field guides' birds, and nothing to add until one is chosen.
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Your photo, Today, "), photo.label)
        XCTAssertTrue(photo.label.contains("Near "), "the run's place: \(photo.label)")
        XCTAssertTrue(app.staticTexts["In your field guides"].waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        let add = app.buttons["name-bird-add"]
        XCTAssertFalse(add.isEnabled, "nothing chosen")

        search(app, for: "calypte")
        let anna = app.buttons["name-bird-Calypte anna"]
        XCTAssertTrue(anna.waitForExistence(timeout: 10), "the scientific name finds it; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(anna.label, "Anna's Hummingbird, Los Angeles, New to you here")
        XCTAssertFalse(app.buttons["name-bird-Selasphorus sasin"].exists, "the search kept only the match")
        anna.tap()
        XCTAssertTrue(add.isEnabled)
        XCTAssertEqual(add.label, "Add and sew patch")
        XCTAssertTrue(app.staticTexts["Anna's Hummingbird, new to you here."].exists, "screen: \(app.debugDescription.prefix(3000))")
        add.tap()

        // An add like any other: the new patch's page, then the run with the bird under Seen this run and Undo.
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "no new patch; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Keep listening"].tap()
        let heading = app.staticTexts["Seen this run"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        let row = app.buttons["seen-row-Calypte anna"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(row.label, "Anna's Hummingbird, Seen, your photo, New patch")
        let heard = app.buttons["Sew it, House Finch"]
        XCTAssertTrue(heard.exists, "what was heard is still there; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertLessThan(heading.frame.minY, heard.frame.minY, "seen birds sit above the heard ones")
        XCTAssertLessThan(row.frame.minY, heard.frame.minY)
        XCTAssertTrue(app.staticTexts["Your first Anna's Hummingbird in Los Angeles"].exists, "the acknowledgment; screen: \(app.debugDescription.prefix(4000))")

        // The row opens the sighting: Seen, your photo, and no match score.
        row.tap()
        XCTAssertTrue(element(app, "sighting-attached-photo").waitForExistence(timeout: 10), "the page leads with the photo; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, "sighting-named-by-you").exists)
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "no Heard or Seen to choose")
        app.navigationBars.buttons.firstMatch.tap()

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "no Undo; screen: \(app.debugDescription.prefix(4000))")
        undo.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Undo left the row")
        XCTAssertFalse(heading.exists, "and the section with it")
        XCTAssertTrue(heard.exists)
    }

    @MainActor
    func testABirdNoFieldGuideDescribesIsFoundUnderAllBirdsAndLandsInUnchartedAndCancelDiscardsThePhoto() throws {
        let app = try launchRun()
        capture(app)

        // Nothing matches: said so, with a way back.
        search(app, for: "zzzz")
        XCTAssertTrue(app.staticTexts["No birds match “zzzz”"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["In your field guides"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["In your field guides"].waitForExistence(timeout: 10), "clearing brings the field guides back")

        // Cancel discards the photo: back on the run with nothing seen.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Seen this run"].exists, "nothing was added")

        // A bird of the world, in no field guide on this iPhone: below them, Uncharted.
        capture(app)
        search(app, for: "amazilia humm")
        XCTAssertTrue(app.staticTexts["All birds"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["In your field guides"].exists, "no field guide has it")
        let amazilia = app.buttons.matching(NSPredicate(format: "label == %@", "Amazilia Hummingbird, Uncharted")).firstMatch
        XCTAssertTrue(amazilia.exists, "screen: \(app.debugDescription.prefix(3000))")
        amazilia.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertEqual(add.label, "Add and sew patch")
        add.tap()
        XCTAssertTrue(app.staticTexts["New patch, Uncharted"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first Amazilia Hummingbird"].exists, "outside every set; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Keep listening"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Amazilia Hummingbird, Seen, your photo, New patch")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")

        // The same bird again: its count, with no page.
        capture(app)
        search(app, for: "amazilia humm")
        let again = app.buttons.matching(NSPredicate(format: "label == %@", "Amazilia Hummingbird, Uncharted, Seen once here")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        again.tap()
        XCTAssertEqual(add.label, "Add sighting")
        add.tap()
        XCTAssertTrue(app.staticTexts["Amazilia Hummingbird seen again, 2 times"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "a repeat has no page")
        let repeated = app.buttons.matching(NSPredicate(format: "label == %@", "Amazilia Hummingbird, Seen 2 times here, your photo")).firstMatch
        XCTAssertTrue(repeated.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testARefusedCameraIsExplainedWithTheWayToSettingsAndClosesBackToTheRun() throws {
        let app = try launchRun(camera: "denied")
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 90), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: capture)
        wait(for: [enabled], timeout: 60)
        capture.tap()

        XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["capture-shutter"].isEnabled, "no photo without a camera")
        XCTAssertTrue(element(app, "capture-listening").exists, "the run is still listening")
        app.buttons["Close camera"].tap()
        XCTAssertTrue(capture.waitForExistence(timeout: 10), "back on the run")
        XCTAssertTrue(app.buttons["Stop listening"].exists)
    }

    /// A glasses run on Mock Device Kit, the clip standing in for its stream: the button is there too, and the phone's camera
    /// takes the photo while the glasses go on listening.
    @MainActor
    func testAGlassesRunOffersCaptureASightingToo() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))",  // the port is the Mac's, and agents test side by side
            "-autoGlassesListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "glasses-run",
            "-fakeCamera", "ready", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ]
        app.launch()
        // The button waits for the run to be listening.
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 120), "the glasses run didn't start; screen: \(app.debugDescription.prefix(4000))")
        capture(app)
        search(app, for: "allen")
        let allens = app.buttons["name-bird-Selasphorus sasin"]
        XCTAssertTrue(allens.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        allens.tap()
        app.buttons["name-bird-add"].tap()
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Keep listening"].tap()
        XCTAssertTrue(app.buttons["seen-row-Selasphorus sasin"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Stop listening"].exists, "the run is still on")
    }
}
