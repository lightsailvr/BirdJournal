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

        let firstRow = app.staticTexts["candidate-status-0"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 60), "no species row appeared; screen: \(app.debugDescription.prefix(3000))")
        let calling = NSPredicate(format: "label == 'Calling now'")
        let callingOnRowOne = expectation(for: calling, evaluatedWith: firstRow)
        wait(for: [callingOnRowOne], timeout: 60)
        XCTAssertTrue(app.staticTexts["Calling now"].exists)

        // The soundscape has quiet stretches: within a minute some bird on the list has stopped and reads as heard.
        let heard = NSPredicate(format: "label BEGINSWITH 'Heard'")
        XCTAssertTrue(app.staticTexts.matching(heard).firstMatch.waitForExistence(timeout: 90), "no bird went quiet; screen: \(app.debugDescription.prefix(3000))")
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
