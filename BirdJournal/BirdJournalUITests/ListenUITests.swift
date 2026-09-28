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

    @MainActor
    func testDeveloperToolsOpenWithoutEndingTheApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()
        let developer = app.buttons["Developer tools"]
        XCTAssertTrue(developer.waitForExistence(timeout: 10))
        developer.tap()
        XCTAssertTrue(app.staticTexts["Developer"].waitForExistence(timeout: 10) || app.navigationBars["Developer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
