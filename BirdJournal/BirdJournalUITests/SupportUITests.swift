import XCTest

/// Settings → Support Featherguild (issue #59): the row opens the tip jar, the copy says tips unlock nothing, and a
/// tip bought against the scheme's StoreKit configuration ends in the thank-you.
final class SupportUITests: XCTestCase {
    @MainActor
    func testSettingsRowOpensTheTipJar() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "settings"]
        app.launch()

        let row = app.buttons["Support Featherguild"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Support row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()

        let promise = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'unlock nothing'")).firstMatch
        XCTAssertTrue(promise.waitForExistence(timeout: 10), "no unlock-nothing copy; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTipEndsInTheThankYou() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "support"]
        app.launch()

        let tip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tip '")).firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 20), "no tips loaded; screen: \(app.debugDescription.prefix(3000))")
        tip.tap()

        // StoreKit testing confirms the purchase in a system sheet.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons.matching(NSPredicate(format: "label IN {'Subscribe', 'Purchase', 'Buy', 'OK', 'Confirm'}")).firstMatch
        if confirm.waitForExistence(timeout: 8) { confirm.tap() }
        let done = springboard.buttons["OK"]
        if done.waitForExistence(timeout: 5) { done.tap() }

        XCTAssertTrue(app.otherElements["tip-thanks"].waitForExistence(timeout: 20), "no thank-you; screen: \(app.debugDescription.prefix(3000))")
    }
}
