import XCTest

// Debug only: the account is switched off in Release (`ACCOUNTS_ENABLED`, issue #88), and `-fakeAccount` is DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

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
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'pat@example.com'")).firstMatch.exists)

        app.buttons["Sign out"].tap()
        // The confirmation's own Sign out, in the dialog over the list.
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch
        let confirm = dialog.buttons["Sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation; screen: \(app.debugDescription.prefix(4000))")
        confirm.tap()
        XCTAssertTrue(app.buttons["Sign in with Apple"].waitForExistence(timeout: 5))
    }
}
#endif
