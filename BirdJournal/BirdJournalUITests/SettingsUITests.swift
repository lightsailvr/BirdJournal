import XCTest

/// Settings → Appearance: the light/dark choice sticks, and picking an app icon changes the home-screen icon (iOS
/// confirms with its own alert) and moves the check.
final class SettingsUITests: XCTestCase {
    @MainActor
    func testAppearanceChoiceIsSelected() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-appearance", "system"]
        app.launch()
        app.buttons["Settings"].tap()

        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 10), "no Dark choice; screen: \(app.debugDescription.prefix(3000))")
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        app.buttons["System"].tap()
        XCTAssertTrue(app.buttons["System"].isSelected)
    }

    @MainActor
    func testPickingAnIconMovesTheCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()

        // The row reads "App icon, <current icon>".
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'App icon'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no App icon row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()

        for title in ["Great Egret", "Red-tailed Hawk"] {
            let choice = app.buttons[title]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            // The system's "You have changed the icon" alert belongs to SpringBoard.
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.waitForExistence(timeout: 5) { alert.buttons.firstMatch.tap() }
            XCTAssertTrue(choice.waitForSelected(), "\(title) is not checked")
        }
    }
}

/// The account's build-time switch (issue #88): on in Debug, Settings has the Account row; off in Release, it has none.
/// The Release case runs in the `BirdJournal-Release` scheme (`scripts/build-and-test.sh --release`). The expectation
/// keys on DEBUG, not on the switch, so turning the account on in Release fails here until #71 updates this test.
final class AccountSwitchUITests: XCTestCase {
    @MainActor
    func testAccountRowFollowsTheBuildSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()

        // The Appearance section is always there, so the list has loaded before the Account row is looked for.
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 10), "Settings didn't open; screen: \(app.debugDescription.prefix(3000))")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch
        #if DEBUG
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Account row in a Debug build")
        #else
        XCTAssertFalse(row.exists, "an Account row in a Release build: \(row.label)")
        XCTAssertFalse(app.staticTexts["ACCOUNT"].exists || app.staticTexts["Account"].exists, "an Account section header")
        #endif
    }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
