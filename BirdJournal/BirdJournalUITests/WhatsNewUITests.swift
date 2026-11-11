import XCTest

/// The "What's new" card with real taps: it arrives over the tabs when asked for, goes with its button, with a tap beside it
/// and with a pull down, comes back from Settings, and stays away unasked (a debug build never shows it by itself, or a test
/// run after a release would find it over every screen).
final class WhatsNewUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoLocation", "denied"] + arguments
        app.launch()
        return app
    }

    private func waitToGo(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor
    func testCardArrivesAtLaunchAndGoesWithItsButton() {
        let app = launch(["-whatsNew", "show"])
        let title = app.staticTexts["whats-new-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no card; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(title.label, "What’s new")
        XCTAssertTrue(app.descendants(matching: .any)["whats-new-item-1"].exists, "no first change")
        let done = app.buttons["whats-new-dismiss"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(waitToGo(title), "the card stayed")
        // The page under it is the app again.
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSettingsBringsItBackAndATapBesideItPutsItAway() {
        let app = launch(["-autoScreen", "settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "no Settings; screen: \(app.debugDescription.prefix(3000))")
        // Unasked, nothing came up over Settings.
        XCTAssertFalse(app.staticTexts["whats-new-title"].exists)
        // The row is near the foot of the list, which only builds its rows as they come into view.
        let row = app.buttons["whatsNewRow"]
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        let title = app.staticTexts["whats-new-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no card from Settings")
        // The dimmed page above the card.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.085)).tap()
        XCTAssertTrue(waitToGo(title), "a tap beside the card left it up")

        // Again, and a pull down puts it away too.
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 320)))
        XCTAssertTrue(waitToGo(title), "a pull down left it up")
    }

    @MainActor
    func testNothingComesUpUnasked() {
        let app = launch([])
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 20))
        // Longer than the card waits for the page to settle.
        XCTAssertFalse(app.staticTexts["whats-new-title"].waitForExistence(timeout: 3))
    }
}
