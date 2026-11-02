import XCTest

// Debug only, like the circles: the account is off in Release (`ACCOUNTS_ENABLED`, issue #88) and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Finds (issue #62) over the debug fake circle server: a circle's page shows its Recent finds with their marks, and
/// Settings → Account has "Share my finds automatically", on by default.
final class FindsUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testACirclePageShowsItsRecentFinds() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        XCTAssertTrue(app.staticTexts["Recent finds"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")

        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "no finds; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(rows.count, 6)
        let newest = rows.element(boundBy: 0).label
        XCTAssertTrue(newest.contains("California Gnatcatcher"), newest)
        XCTAssertTrue(newest.contains("At a secret spot"), newest)
        XCTAssertTrue(newest.contains("First for the circle"), newest)
        XCTAssertTrue(newest.contains("Rare"), newest)
        let oldest = rows.element(boundBy: 3).label
        XCTAssertTrue(oldest.contains("Seen by Maya Ortiz") && oldest.contains("Legendary") && oldest.contains("First for the circle"), oldest)
        let later = rows.element(boundBy: 1).label
        XCTAssertTrue(later.contains("Black Phoebe") && !later.contains("First for the circle"), later)
    }

    @MainActor
    func testSharingIsOnByDefaultAndOffIsPrivate() {
        let app = launch(["-fakeAccount", "signedIn"])
        app.buttons["Settings"].tap()
        let toggle = app.switches["shareFindsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never the exact spot'")).firstMatch.exists)

        // The setting is the app's own default: put it back however the test ends.
        defer { if toggle.value as? String == "0" { toggle.switches.firstMatch.tap() } }
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'stay on this iPhone'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
#endif
