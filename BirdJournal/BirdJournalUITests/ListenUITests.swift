import XCTest

/// The taps a finger makes (issue #28, from a device report that Start listening did nothing): Start on the Listen
/// tab must change the screen, and Settings → Developer tools must not end the app.
final class ListenUITests: XCTestCase {
    @MainActor
    func testStartListeningChangesTheScreen() {
        // With a journal: the latest sighting's card, with a portrait glasses frame, sits under the button.
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES"]
        app.launch()

        let start = app.buttons["Start listening"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no Start listening button; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(start.isHittable, "Start listening is not hittable")
        start.tap()

        let started = app.staticTexts["Listening"].waitForExistence(timeout: 10)
            || app.buttons["Stop listening"].waitForExistence(timeout: 5)
            || app.staticTexts["Last run"].waitForExistence(timeout: 5)
        XCTAssertTrue(started, "the screen did not change after Start; screen: \(app.debugDescription.prefix(4000))")
    }

    /// Listen's own bar is inline, so that only the gear sits over the painting (issue #150). A pushed page inherits that
    /// unless it says otherwise, and these two have large titles.
    @MainActor
    func testPagesPushedFromListenKeepTheirLargeTitles() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        gear.tap()
        let settings = app.navigationBars["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertGreaterThan(settings.frame.height, 80, "inline is 54 pt, large 106 pt")
        settings.buttons.element(boundBy: 0).tap()

        let explore = app.buttons["Explore the Los Angeles set"]
        XCTAssertTrue(explore.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        explore.tap()
        let set = app.navigationBars["Los Angeles"]
        XCTAssertTrue(set.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertGreaterThan(set.frame.height, 130, "with the search drawer, inline is 108 pt, large 160 pt")
    }

    /// Heard or Seen is on the review sheet itself (issue #150, guide board 03), Heard until the birder says otherwise.
    @MainActor
    func testTheReviewSheetAsksHeardOrSeen() throws {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
        guard FileManager.default.fileExists(atPath: clip.path(percentEncoded: false)) else {
            throw XCTSkip("no example soundscape at \(clip.path(percentEncoded: false))")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoPhoneListening", clip.path(percentEncoded: false), "-autoLocation", "griffith", "-autoScreen", "review"]
        app.launch()
        let method = app.segmentedControls["review-method"]
        XCTAssertTrue(method.waitForExistence(timeout: 60), "no picker; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(method.buttons["Heard"].isSelected)
        method.buttons["Seen"].tap()
        XCTAssertTrue(method.buttons["Seen"].isSelected)
    }

    /// Issue #42: a run over the example soundscape marks the bird calling now on row one, and the marker gives way
    /// to a heard time once the bird goes quiet. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
    @MainActor
    func testCallingNowMarksTheFirstRow() throws {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
        guard FileManager.default.fileExists(atPath: clip.path(percentEncoded: false)) else {
            throw XCTSkip("no example soundscape at \(clip.path(percentEncoded: false))")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoPhoneListening", clip.path(percentEncoded: false), "-autoLocation", "denied", "-autoScreen", "listening"]
        app.launch()

        let firstRow = app.buttons["candidate-row-0"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 60), "no species row appeared; screen: \(app.debugDescription.prefix(3000))")
        let calling = NSPredicate(format: "label CONTAINS ', calling now,'")
        let callingOnRowOne = expectation(for: calling, evaluatedWith: firstRow)
        wait(for: [callingOnRowOne], timeout: 60)

        // The soundscape has quiet stretches: within a minute some bird on the list has stopped and reads as heard.
        let heard = NSPredicate(format: "label CONTAINS ', heard '")
        XCTAssertTrue(app.buttons.matching(heard).firstMatch.waitForExistence(timeout: 90), "no bird went quiet; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testDeveloperToolsOpenWithoutEndingTheApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()
        let developer = app.buttons["Developer tools"]
        // The last row of Settings, below the fold on a small phone.
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 10))
        for _ in 0..<4 where !developer.isHittable { app.swipeUp() }
        XCTAssertTrue(developer.waitForExistence(timeout: 10))
        developer.tap()
        XCTAssertTrue(app.staticTexts["Developer"].waitForExistence(timeout: 10) || app.navigationBars["Developer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
