import XCTest

/// Issue #191 (of #185): real taps from "Capture a sighting" on the idle Listen tab, with no run, through the camera and
/// "Name this bird" to the acknowledgment on the idle tab, and then into a run that knows nothing of it. The simulator has no
/// camera, so a stand-in is behind the button (`-fakeCamera`), and `-autoLocation` answers for where the phone is.
final class IdleCaptureUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// The idle Listen tab over an empty album. Reduce Motion, so a new patch's page is the finished patch at once, and the
    /// acknowledgment held long enough to reach its Undo.
    @MainActor
    private func launchIdle(location: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoLocation", location, "-autoScreen", "listen",
            "-fakeCamera", "ready", "-reduceMotion", "YES", "-acknowledgmentSeconds", "90",
        ] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Opens the camera from the idle tab and takes the photo: "Name this bird" is up when this returns.
    @MainActor
    private func capture(_ app: XCUIApplication) {
        let capture = app.buttons["capture-sighting"]
        XCTAssertTrue(capture.waitForExistence(timeout: 60), "no Capture a sighting; screen: \(app.debugDescription.prefix(3000))")
        capture.tap()
        let shutter = app.buttons["capture-shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "no camera; screen: \(app.debugDescription.prefix(3000))")
        let ready = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: shutter)
        wait(for: [ready], timeout: 15)
        XCTAssertFalse(element(app, "capture-listening").exists, "no run, so nothing said of one; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["capture-library"].exists)
        shutter.tap()
        XCTAssertTrue(app.navigationBars["Name this bird"].waitForExistence(timeout: 15), "no naming; screen: \(app.debugDescription.prefix(3000))")
    }

    /// Searches for Anna's Hummingbird, chooses it and adds: the sheet closes on the new patch's page.
    @MainActor
    private func nameAsAnnas(_ app: XCUIApplication, expecting label: String) {
        let field = app.textFields["name-bird-search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field; screen: \(app.debugDescription.prefix(3000))")
        field.tap()
        // Return puts the keyboard away, so the results and the pinned add are all in reach.
        field.typeText("calypte\n")
        let anna = app.buttons["name-bird-Calypte anna"]
        XCTAssertTrue(anna.waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(anna.label, label)
        anna.tap()
        let add = app.buttons["name-bird-add"]
        XCTAssertEqual(add.label, "Add and sew patch")
        add.tap()
        XCTAssertTrue(app.buttons["Share this patch"].waitForExistence(timeout: 15), "no new patch's page; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testASightingIsCapturedAndNamedWithNoRunAndARunStartedAfterwardsCountsNoneOfIt() throws {
        let app = launchIdle(location: "griffith", ["-autoPhoneListening", try Self.clip()])

        // The idle tab: Start listening as it was, and the capture under it, both in reach above the tab bar.
        let start = app.buttons["Start listening"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "screen: \(app.debugDescription.prefix(3000))")
        let button = app.buttons["capture-sighting"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Capture a sighting on the idle tab; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(button.label, "Capture a sighting")
        XCTAssertTrue(start.isHittable && button.isHittable)
        XCTAssertGreaterThan(button.frame.minY, start.frame.maxY, "under Start listening")
        XCTAssertGreaterThan(start.frame.width, button.frame.width + 60, "Start stays the wide one")
        XCTAssertLessThan(button.frame.maxY, app.tabBars.firstMatch.frame.minY, "on the first screen")
        XCTAssertTrue(app.staticTexts["Wonder is nearby."].exists, "the painting's words are as they were")

        capture(app)

        // The same sheet, with where the phone is now and what is likely there; nothing is called heard.
        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasPrefix("Your photo, Today, "), photo.label)
        XCTAssertTrue(photo.label.contains("Near "), "the phone's place: \(photo.label)")
        XCTAssertTrue(app.staticTexts["Likely here now"].waitForExistence(timeout: 30), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["Heard this run"].exists, "there is no run")
        nameAsAnnas(app, expecting: "Anna's Hummingbird, Los Angeles, New to you here")

        // The add: its new patch's page at once, then the idle tab with the acknowledgment and its Undo.
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].exists, "screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["New patch, Citrus edition"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(start.waitForExistence(timeout: 10), "not back on the idle tab; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first Anna's Hummingbird in Los Angeles"].waitForExistence(timeout: 10), "no acknowledgment on the idle tab; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Undo"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts["Seen this run"].exists, "there is no run to have seen it on")
        XCTAssertTrue(button.exists && start.isEnabled)

        // A run started now is a run like any other, and the sighting is none of its.
        start.tap()
        XCTAssertTrue(app.buttons["Stop listening"].waitForExistence(timeout: 60), "the run didn't start; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts["Seen this run"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["seen-row-Calypte anna"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists, "the earlier add's acknowledgment went with Start")
        XCTAssertTrue(app.buttons["capture-sighting"].waitForExistence(timeout: 10), "the run has its own")

        // And it is in the Collection.
        app.tabBars.buttons["Collection"].tap()
        let patch = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Anna's Hummingbird")).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 20), "the sighting isn't in the Collection; screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testWithLocationRefusedThePlaceIsNotRecordedAndUndoOnTheIdleTabTakesTheNameBack() throws {
        let app = launchIdle(location: "denied")
        capture(app)

        let photo = element(app, "name-bird-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertTrue(photo.label.hasSuffix(", Place not recorded"), photo.label)
        XCTAssertFalse(app.staticTexts["Heard this run"].exists)
        // A sighting without a place lands in Uncharted, as it does today.
        nameAsAnnas(app, expecting: "Anna's Hummingbird, Uncharted, New to you here")
        app.buttons["Done"].firstMatch.tap()

        let said = app.staticTexts["Your first Anna's Hummingbird"]
        XCTAssertTrue(said.waitForExistence(timeout: 10), "no acknowledgment on the idle tab; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Start listening"].exists)
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(said.waitForNonExistence(timeout: 10), "Undo left the acknowledgment")
        XCTAssertTrue(app.buttons["Start listening"].exists && app.buttons["capture-sighting"].exists, "still the idle tab")
        XCTAssertFalse(app.staticTexts["Seen this run"].exists)
    }
}
