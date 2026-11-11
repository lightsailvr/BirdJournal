import XCTest

/// Issue #190 (of #185): real taps on "Change bird". A sighting the birder named is opened from "Seen this run" or from the
/// Collection, the naming sheet opens on it, and another bird is chosen: the page, its patch and the run's row are the new
/// bird's, and no stitch-in plays for the patch the change sewed. A sighting BirdNET heard has no such button.
final class ChangeBirdUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Taps "Change bird" on the sighting's page showing, scrolling it clear of the bars first, and waits for the sheet.
    @MainActor
    private func openChangeBird(_ app: XCUIApplication) {
        let change = app.buttons["sighting-change-bird"]
        XCTAssertTrue(change.waitForExistence(timeout: 15), "no Change bird; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(change.label, "Change bird")
        // A button low on the page is hittable under the tab bar, where a tap lands on the bar.
        if change.frame.maxY > app.frame.height * 0.75 { app.swipeUp(velocity: .slow) }
        change.tap()
        XCTAssertTrue(app.navigationBars["Change bird"].waitForExistence(timeout: 15), "no sheet; screen: \(app.debugDescription.prefix(4000))")
    }

    /// Searches the sheet and chooses the bird with this scientific name.
    @MainActor
    private func choose(_ app: XCUIApplication, search text: String, scientificName: String) -> XCUIElement {
        let field = app.textFields["name-bird-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field; screen: \(app.debugDescription.prefix(3000))")
        field.tap()
        // Return puts the keyboard away, so the results and the pinned button are all in reach.
        field.typeText(text + "\n")
        let row = app.buttons["name-bird-\(scientificName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no \(scientificName); screen: \(app.debugDescription.prefix(4000))")
        return row
    }

    /// On a run: the bird named a moment ago is changed from its row under "Seen this run", and the run follows.
    @MainActor
    func testABirdSeenThisRunIsChangedFromItsPageAndTheRunFollowsWithNoStitchIn() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeRunBirds", "Haemorhous mexicanus_House Finch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
            "-fakeCamera", "ready", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
            "-autoSeen", "Selasphorus sasin",
        ]
        app.launch()
        let row = app.buttons["seen-row-Selasphorus sasin"]
        XCTAssertTrue(row.waitForExistence(timeout: 120), "no seen bird; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(row.label, "Allen's Hummingbird, Seen, your photo, New patch")
        XCTAssertTrue(app.staticTexts["Your first Allen's Hummingbird in Los Angeles"].waitForExistence(timeout: 10), "the add's acknowledgment; screen: \(app.debugDescription.prefix(4000))")

        row.tap()
        XCTAssertTrue(app.navigationBars["Allen's Hummingbird"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, "sighting-named-by-you").waitForExistence(timeout: 10))
        openChangeBird(app)

        // The sheet is the naming sheet, on the sighting: its bird, nothing to name later or delete, nothing to press yet.
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Allen's Hummingbird, your photo, Today, "), photo.label)
        XCTAssertTrue(app.buttons["change-bird-cancel"].exists)
        XCTAssertFalse(app.buttons["name-bird-later"].exists)
        XCTAssertFalse(app.buttons["name-bird-delete"].exists)
        let confirm = app.buttons["change-bird-confirm"]
        XCTAssertTrue(confirm.exists)
        XCTAssertFalse(confirm.isEnabled, "nothing chosen")
        XCTAssertTrue(app.staticTexts["Heard this run"].waitForExistence(timeout: 30), "the run's birds are suggested for a bird seen on it; screen: \(app.debugDescription.prefix(4000))")

        let anna = choose(app, search: "calypte", scientificName: "Calypte anna")
        XCTAssertEqual(anna.label, "Anna's Hummingbird, Los Angeles, New to you here")
        anna.tap()
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.label, "Change and sew patch")
        XCTAssertTrue(
            app.staticTexts["Anna's Hummingbird, new to you here. Your Allen's Hummingbird patch in Los Angeles will be unpicked."].exists,
            "screen: \(app.debugDescription.prefix(4000))"
        )
        confirm.tap()

        // The sheet closes on the same page, now the new bird's, and nothing is celebrated: no stitch-in, no new patch's page.
        XCTAssertTrue(app.navigationBars["Change bird"].waitForNonExistence(timeout: 15), "the sheet stayed; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.navigationBars["Anna's Hummingbird"].waitForExistence(timeout: 15), "the page isn't the new bird's; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, "sighting-attached-photo").exists, "its photo is still its own")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(element(app, "stitch-in").exists, "a stitch-in played for a change")
        XCTAssertFalse(element(app, "revealed-patch").exists, "a new patch's page opened for a change")
        XCTAssertFalse(app.staticTexts["New patch, Citrus edition"].exists)
        XCTAssertTrue(app.navigationBars["Anna's Hummingbird"].exists)

        // Back on the run: the row is the new bird's, and the acknowledgment that named the old one has gone.
        app.navigationBars.buttons.firstMatch.tap()
        let changed = app.buttons["seen-row-Calypte anna"]
        XCTAssertTrue(changed.waitForExistence(timeout: 15), "the run's row didn't follow; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(changed.label, "Anna's Hummingbird, Seen, your photo, New patch")
        XCTAssertFalse(app.buttons["seen-row-Selasphorus sasin"].exists)
        XCTAssertFalse(app.staticTexts["Your first Allen's Hummingbird in Los Angeles"].exists, "the old bird's acknowledgment stayed")
        XCTAssertFalse(app.buttons["Undo"].exists)
    }

    /// From the Collection, days later: the bird is changed to one that already has a patch there, the old bird's patch is
    /// unpicked, and a heard sighting's page offers no change.
    @MainActor
    func testANamedSightingInTheCollectionChangesToABirdWithAPatchAndAHeardOneCannot() throws {
        let app = XCUIApplication()
        let seeded = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-seedSeen", "Selasphorus sasin", "-collectionIntroShown", "YES", "-reduceMotion", "YES"]
        app.launchArguments = seeded + ["-autoScreen", "sighting", "-autoCardSpecies", "Selasphorus sasin"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Allen's Hummingbird"].waitForExistence(timeout: 90), "no sighting's page; screen: \(app.debugDescription.prefix(4000))")
        openChangeBird(app)
        let confirm = app.buttons["change-bird-confirm"]

        // The House Finch has been heard twice in Los Angeles: the change adds to its patch and sews none.
        let finch = choose(app, search: "house finch", scientificName: "Haemorhous mexicanus")
        XCTAssertEqual(finch.label, "House Finch, Los Angeles, Seen 2 times here")
        finch.tap()
        XCTAssertEqual(confirm.label, "Change bird")
        XCTAssertTrue(
            app.staticTexts["House Finch, seen 2 times here. Your Allen's Hummingbird patch in Los Angeles will be unpicked."].exists,
            "screen: \(app.debugDescription.prefix(4000))"
        )
        confirm.tap()
        XCTAssertTrue(app.navigationBars["House Finch"].waitForExistence(timeout: 15), "the page isn't the new bird's; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, "sighting-named-by-you").exists, "still a bird the birder saw and named")
        XCTAssertFalse(element(app, "stitch-in").exists)
        XCTAssertFalse(element(app, "revealed-patch").exists)

        // The sheet opens again on the House Finch, and Cancel leaves it. (Nothing is typed this time: a second keyboard in
        // one launch has hung XCUITest's idle wait, #188 and #189. The bird it is being marked is held in process.)
        openChangeBird(app)
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("House Finch, your photo, "), photo.label)
        app.buttons["change-bird-cancel"].tap()
        XCTAssertTrue(app.navigationBars["Change bird"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["House Finch"].exists, "Cancel changed nothing")

        // A sighting BirdNET heard: the Black Phoebe.
        app.terminate()
        app.launchArguments = seeded + ["-autoScreen", "sighting", "-autoCardSpecies", "Sayornis nigricans"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Black Phoebe"].waitForExistence(timeout: 90), "no sighting's page; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 10), "Heard or Seen, for a bird BirdNET heard")
        XCTAssertFalse(app.buttons["sighting-change-bird"].exists, "a heard sighting has no Change bird")
        XCTAssertFalse(element(app, "sighting-named-by-you").exists)
    }
}
