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
        let field = app.textFields["name-bird-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field; screen: \(app.debugDescription.prefix(3000))")
        if let typed = field.value as? String, typed != field.placeholderValue, !typed.isEmpty {
            app.buttons["Clear text"].tap()
        }
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

        // Name this bird: the photo, the suggestions (#189), and nothing to add until a bird is chosen.
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Your photo, Today, "), photo.label)
        XCTAssertTrue(photo.label.contains("Near "), "the run's place: \(photo.label)")
        XCTAssertTrue(app.staticTexts["Likely here now"].waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        let add = app.buttons["name-bird-add"]
        XCTAssertFalse(add.isEnabled, "nothing chosen")

        search(app, for: "calypte")
        let anna = app.buttons["name-bird-Calypte anna"]
        XCTAssertTrue(anna.waitForExistence(timeout: 10), "the scientific name finds it; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["In your field guides"].exists, "screen: \(app.debugDescription.prefix(3000))")
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

        // Undo takes the name back, and never the photo (issue #188): it waits again as an unnamed sighting.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "no Undo; screen: \(app.debugDescription.prefix(4000))")
        undo.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "Undo left the row")
        let unnamed = app.buttons["unnamed-row"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 10), "the photo went with the name; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(unnamed.label.hasPrefix("Unnamed sighting, Your photo, "), unnamed.label)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(heard.exists)
    }

    @MainActor
    func testNameItLaterKeepsThePhotoOnTheRunAndABirdNoFieldGuideDescribesLandsInUncharted() throws {
        let app = try launchRun()
        capture(app)

        // Nothing matches: said so, with a way back.
        search(app, for: "zzzz")
        XCTAssertTrue(app.staticTexts["No birds match “zzzz”"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["In your field guides"].exists)
        XCTAssertFalse(app.staticTexts["Likely here now"].exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["Likely here now"].waitForExistence(timeout: 10), "clearing brings the suggestions back")

        // Name it later keeps the photo (issue #188): back on the run, it waits under Seen this run with Name it, above the
        // birds heard, having earned nothing.
        XCTAssertFalse(app.buttons["Cancel"].exists, "nothing here discards the photo")
        app.buttons["Name it later"].tap()
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Seen this run"].waitForExistence(timeout: 10), "the photo was lost; screen: \(app.debugDescription.prefix(4000))")
        let unnamed = app.buttons["unnamed-row"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(unnamed.label, "Unnamed sighting, Your photo, just now, Name it")
        XCTAssertEqual(app.buttons.matching(identifier: "unnamed-row").count, 1)
        XCTAssertLessThan(unnamed.frame.minY, app.buttons["Sew it, House Finch"].frame.minY, "above the birds heard")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "no patch for a photo with no name")
        XCTAssertFalse(app.buttons["Undo"].exists, "nothing was added")

        // Name it from its row: the same sheet, the same photo. A bird of the world, in no field guide on this iPhone: below
        // them, Uncharted.
        unnamed.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming from the row; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(element(app, "name-bird-photo").label.hasPrefix("Your photo, Today, "), element(app, "name-bird-photo").label)
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
        XCTAssertFalse(unnamed.exists, "named, it is a sighting and no longer waits")

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

    /// Issue #189: before anything is typed the sheet offers the bird the run has heard, then the field guide's birds the
    /// geomodel finds most likely in Griffith Park this week (the bundled geomodel, so which birds depends on the date the
    /// test runs). Typing replaces both with the search, clearing the field brings them back, and a suggestion is chosen and
    /// added like any other bird.
    @MainActor
    func testTheSheetOpensOnWhatTheRunHeardAndWhatIsLikelyHereAndTypingReplacesThem() throws {
        let app = try launchRun()
        capture(app)

        let heard = app.staticTexts["Heard this run"]
        XCTAssertTrue(heard.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        let likely = app.staticTexts["Likely here now"]
        XCTAssertTrue(likely.exists, "screen: \(app.debugDescription.prefix(3000))")
        let finch = app.buttons["name-bird-Haemorhous mexicanus"]
        XCTAssertTrue(finch.exists, "the run's bird; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(finch.label, "House Finch, Los Angeles, New to you here")
        XCTAssertLessThan(heard.frame.minY, finch.frame.minY)
        XCTAssertLessThan(finch.frame.maxY, likely.frame.minY + 1, "the run's bird sits under Heard this run, above the likely birds")
        XCTAssertFalse(app.staticTexts["In your field guides"].exists, "the suggestions stand in for the list by name")
        XCTAssertFalse(app.staticTexts["All birds"].exists)
        let suggested = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "name-bird-", "name-bird-add"))
        XCTAssertGreaterThan(suggested.count, 2, "likely birds are listed under the heading; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons.matching(identifier: "name-bird-Haemorhous mexicanus").count, 1, "the bird heard isn't listed again as likely")

        // Typing replaces both with the search. The keyboard stays up, as it does while a birder types.
        let field = app.textFields["name-bird-search"]
        field.tap()
        field.typeText("calypte")
        XCTAssertTrue(app.buttons["name-bird-Calypte anna"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(heard.exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(likely.exists)
        XCTAssertFalse(finch.exists)
        XCTAssertTrue(app.staticTexts["In your field guides"].exists)

        // Clearing the field brings them back.
        app.buttons["Clear text"].tap()
        XCTAssertTrue(heard.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(likely.exists)
        XCTAssertFalse(app.staticTexts["In your field guides"].exists)
        field.typeText("\n")  // the keyboard away: the suggestions and the pinned add are all in reach

        // The bird the run heard was the one at the feeder: chosen without typing, and added as seen.
        XCTAssertTrue(finch.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        finch.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertTrue(add.isEnabled)
        XCTAssertEqual(add.label, "Add and sew patch")
        add.tap()
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "no new patch; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Keep listening"].tap()
        let row = app.buttons["seen-row-Haemorhous mexicanus"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(row.label, "House Finch, Seen, your photo, New patch")
    }

    // Issue #188: photo first, name second.

    /// Taps the Done of a new patch's page. A review under the page has a Done in its bar, and the run's page under that has
    /// one at its foot, so this takes the one sitting just above the page's own "Share this patch".
    @MainActor
    private func closeNewPatchPage(_ app: XCUIApplication) {
        let share = app.buttons["Share this patch"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "no new patch's page; screen: \(app.debugDescription.prefix(4000))")
        let shareTop = share.frame.minY
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
        let own = done.filter { $0.frame.maxY <= shareTop }.max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(own, "no Done above Share; Done at \(done.map(\.frame)), Share at \(share.frame)")
        own?.tap()
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForNonExistence(timeout: 10), "the page didn't close; Done at \(done.map(\.frame)), Share at \(share.frame)")
    }

    @MainActor
    func testAnUnnamedSightingIsDeletedOnlyAfterAConfirmation() throws {
        let app = try launchRun()
        capture(app)
        app.buttons["Name it later"].tap()
        let unnamed = app.buttons["unnamed-row"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")

        // Delete asks first, and Keep photo keeps it.
        unnamed.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15))
        let delete = app.buttons["name-bird-delete"]
        XCTAssertEqual(delete.label, "Delete photo")
        delete.tap()
        let alert = app.alerts["Delete this photo?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(alert.staticTexts["The unnamed sighting and its photo are deleted. This can't be undone."].exists, "screen: \(app.debugDescription.prefix(4000))")
        alert.buttons["Keep photo"].tap()
        let sheet = app.navigationBars["Name this bird"]
        XCTAssertTrue(sheet.exists, "still here to be named")

        // Closing the sheet by pulling it down keeps the photo, as Name it later does.
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet didn't close; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(unnamed.waitForExistence(timeout: 10), "closing the sheet lost the photo; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.buttons.matching(identifier: "unnamed-row").count, 1)

        // Confirmed, it goes, and the section with its only row.
        unnamed.tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 15))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        alert.buttons["Delete photo"].tap()
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 10), "back on the run")
        XCTAssertTrue(unnamed.waitForNonExistence(timeout: 10), "the row is still there")
        XCTAssertFalse(app.staticTexts["Seen this run"].exists)
        XCTAssertTrue(app.buttons["Sew it, House Finch"].exists, "the run is as it was")
    }

    /// The app is killed with "Name this bird" open, nothing tapped. At the next launch, with no run, the photo waits in the
    /// Collection under "To name", and naming it there sews its patch in the set of the place it was taken.
    @MainActor
    func testAPhotoSurvivesTheAppBeingKilledAndIsNamedFromTheCollection() throws {
        let album = "unnamed-\(UUID().uuidString)"
        let app = XCUIApplication()
        // Not the in-memory album: this one is on disk, as a birder's is.
        app.launchArguments = [
            "-albumFile", album, "-collectionIntroShown", "YES", "-fakeRunBirds", "Haemorhous mexicanus_House Finch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
            "-fakeCamera", "ready", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ]
        app.launch()
        capture(app)
        app.terminate()

        app.launchArguments = ["-albumFile", album, "-collectionIntroShown", "YES", "-autoLocation", "griffith", "-autoScreen", "sightings", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90"]
        app.launch()
        XCTAssertTrue(app.staticTexts["To name"].waitForExistence(timeout: 60), "the photo didn't survive; screen: \(app.debugDescription.prefix(4000))")
        let unnamed = app.buttons["unnamed-row"]
        XCTAssertTrue(unnamed.waitForExistence(timeout: 5))
        XCTAssertTrue(unnamed.label.hasPrefix("Unnamed sighting, Your photo, "), unnamed.label)
        XCTAssertTrue(unnamed.label.hasSuffix(", Name it"), unnamed.label)
        XCTAssertTrue(app.staticTexts["Your first patch is a bird away."].exists, "it is no sighting: the collection is still empty; screen: \(app.debugDescription.prefix(4000))")

        unnamed.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.label.hasPrefix("Your photo, Today, "), photo.label)
        XCTAssertTrue(photo.label.contains("Near "), "the place it was taken, kept from the shutter: \(photo.label)")
        search(app, for: "calypte")
        let anna = app.buttons["name-bird-Calypte anna"]
        XCTAssertTrue(anna.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(anna.label, "Anna's Hummingbird, Los Angeles, New to you here", "placed where the photo was taken")
        anna.tap()
        app.buttons["name-bird-add"].tap()

        // An add made on the phone, with no run on: the new patch's page there and then.
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "no new patch; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first Anna's Hummingbird in Los Angeles"].exists, "screen: \(app.debugDescription.prefix(4000))")
        closeNewPatchPage(app)
        XCTAssertTrue(app.staticTexts["To name"].waitForNonExistence(timeout: 10), "named, it no longer waits; screen: \(app.debugDescription.prefix(4000))")

        // And it stays named.
        app.terminate()
        app.launch()
        let sighting = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Anna's Hummingbird, ")).firstMatch
        XCTAssertTrue(sighting.waitForExistence(timeout: 60), "the sighting isn't in the Collection; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts["To name"].exists)
        XCTAssertFalse(app.buttons["unnamed-row"].exists)
    }

    /// A run ends with a photo still unnamed: the review lists it under "Seen this run", says it is kept, and names it there.
    @MainActor
    func testTheRunsReviewListsAnUnnamedSightingAndNamesItThere() throws {
        let app = try launchRun(["-autoUnnamed", "1", "-autoRunStops", "YES"])
        XCTAssertTrue(app.navigationBars["Your run"].waitForExistence(timeout: 120), "no review; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Seen this run"].firstMatch.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        // The run's own page is under the review and lists it too: the review's row is the one on top, the last.
        let rows = app.buttons.matching(identifier: "unnamed-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        let unnamed = rows.element(boundBy: rows.count - 1)
        XCTAssertTrue(app.staticTexts["Photos you haven't named are kept. Name them any time in Collection, under Sightings."].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertLessThan(unnamed.frame.minY, app.staticTexts["What you heard"].frame.minY, "above what was heard")

        unnamed.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        // The photo is of the run under review, so what the run heard is suggested first (#189).
        XCTAssertTrue(app.staticTexts["Heard this run"].waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["name-bird-Haemorhous mexicanus"].exists, "screen: \(app.debugDescription.prefix(3000))")
        search(app, for: "allen")
        let allens = app.buttons["name-bird-Selasphorus sasin"]
        XCTAssertTrue(allens.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        allens.tap()
        app.buttons["name-bird-add"].tap()

        // The run has ended: the patch is sewn now, on the phone, over the review.
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForExistence(timeout: 15), "no new patch; screen: \(app.debugDescription.prefix(4000))")
        closeNewPatchPage(app)
        XCTAssertTrue(app.navigationBars["Your run"].exists, "still in the review")
        XCTAssertTrue(app.buttons.matching(identifier: "seen-row-Selasphorus sasin").firstMatch.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(rows.count, 0, "named, it no longer waits anywhere")
    }

    /// With sightings in the Collection, "To name" leads the Sightings, and a photo named there joins them.
    @MainActor
    func testToNameLeadsTheSightingsAndAPhotoNamedThereJoinsThem() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedJournal", "YES", "-seedUnnamed", "2",
            "-autoLocation", "denied", "-autoScreen", "sightings", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ]
        app.launch()
        let heading = app.staticTexts["To name"]
        XCTAssertTrue(heading.waitForExistence(timeout: 60), "screen: \(app.debugDescription.prefix(4000))")
        let rows = app.buttons.matching(identifier: "unnamed-row")
        XCTAssertEqual(rows.count, 2)
        let summary = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " sightings")).firstMatch
        XCTAssertTrue(summary.exists, "screen: \(app.debugDescription.prefix(4000))")
        let before = summary.label
        XCTAssertLessThan(summary.frame.minY, heading.frame.minY)
        XCTAssertLessThan(rows.element(boundBy: 1).frame.maxY, app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Today, ")).firstMatch.frame.minY, "above the days")

        // A bird the seeds have already: a repeat, so no page, and its acknowledgment with Undo here in the Collection.
        rows.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        // No run, and the phone may not know where it is now: the suggestions (#189) are the birds likely where and when the
        // photo was taken, in Griffith Park on an earlier day, and nothing is called heard.
        XCTAssertTrue(app.staticTexts["Likely here now"].waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["Heard this run"].exists)
        XCTAssertFalse(app.staticTexts["In your field guides"].exists)
        search(app, for: "black phoebe")
        let phoebe = app.buttons["name-bird-Sayornis nigricans"]
        XCTAssertTrue(phoebe.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        phoebe.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertEqual(add.label, "Add sighting")
        add.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForNonExistence(timeout: 10))
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Black Phoebe seen again, ")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 10), "no acknowledgment in the Collection; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(rows.count, 1, "one still waits")
        XCTAssertNotEqual(summary.label, before, "the named one is a sighting now: \(summary.label)")

        // Undo takes the name back: two wait again, and the totals are as they were.
        app.buttons["Undo"].tap()
        let two = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: rows)
        wait(for: [two], timeout: 10)
        XCTAssertEqual(summary.label, before)
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
