import XCTest

/// Settings → Account (issue #60) with the debug fake auth client (`-fakeAccount`): signed out it offers Apple and
/// Google and says the account is optional; signing in shows the name, and signing out comes back to the buttons.
final class AccountUITests: XCTestCase {
    @MainActor
    func testSignedOutSettingsOffersAppleAndGoogle() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedOut"]
        app.launch()
        app.buttons["Settings"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Account row; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(row.label.contains("Not signed in"), row.label)
        row.tap()

        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sign in with Google"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'An account is optional'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Sign out"].exists)
    }

    @MainActor
    func testSigningInAndOut() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedOut"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Account'")).firstMatch.tap()

        app.buttons["Sign in with Apple"].tap()
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "not signed in; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(name.value as? String, "Pat Birder")
        XCTAssertTrue(app.staticTexts["pat@example.com"].exists)

        app.buttons["Sign out"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Sign out'")).element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
    }
}
