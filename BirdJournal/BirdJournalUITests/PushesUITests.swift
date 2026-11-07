import XCTest

// Debug only: pushes need the account, switched off in Release (`ACCOUNTS_ENABLED`, issue #88), and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Pushes on the phone (issue #63) over the fake circle server and a fake notification permission
/// (`-fakePushPermission`, `-fakePushGrant`): the explanation comes at the first circle and only then, a denial leaves a
/// way to Settings, and a circle and a friend can be muted.
final class PushesUITests: XCTestCase {
    private let explanation = "Hear about your friends' finds"

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-fakeAccount", "signedIn"] + arguments
        app.launch()
        return app
    }

    private func create(_ name: String, in app: XCUIApplication) {
        app.buttons["New Guild"].firstMatch.tap()
        let field = app.textFields["Guild name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        field.typeText(name)
        app.buttons["Create"].tap()
    }

    /// With one Guild the tab already is its page (issue #150).
    private func open(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts[name].exists, "screen: \(app.debugDescription.prefix(3000))")
    }

    /// The settings are the last section of the Info sheet, below the goals and the members.
    private func scrollToSettings(_ app: XCUIApplication) {
        app.openGuildInfo()
        app.scrolledInGuildInfo(to: app.buttons["Leave Guild"])
    }

    @MainActor
    func testTheFirstCircleExplainsPushesOnceAndAllowingThemTurnsThemOn() {
        let app = launch(["-fakeCircles", "empty", "-fakePushPermission", "notDetermined"])
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // Opening the tab asks nothing.
        XCTAssertFalse(app.alerts[explanation].waitForExistence(timeout: 2))

        create("Backyard Crew", in: app)
        let alert = app.alerts[explanation]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no explanation; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'mute a Guild or a friend'")).firstMatch.exists)
        alert.buttons["Turn on notifications"].tap()

        open("Backyard Crew", in: app)
        scrollToSettings(app)
        XCTAssertTrue(app.switches["Mute this Guild"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Turn on notifications"].exists)
        XCTAssertFalse(app.buttons["Open notification settings"].exists)

        app.navigationBars.buttons["Done"].tap()
        create("Weekday Walkers", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Weekday Walkers'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts[explanation].waitForExistence(timeout: 3), "asked again at the second Guild")
    }

    @MainActor
    func testADenialLeavesAWayToSettings() {
        let app = launch(["-fakeCircles", "empty", "-fakePushPermission", "notDetermined", "-fakePushGrant", "NO"])
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        create("Backyard Crew", in: app)
        let alert = app.alerts[explanation]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no explanation; screen: \(app.debugDescription.prefix(3000))")
        alert.buttons["Turn on notifications"].tap()

        open("Backyard Crew", in: app)
        scrollToSettings(app)
        XCTAssertTrue(app.buttons["Open notification settings"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Notifications are off for Featherguild'")).firstMatch.exists)
    }

    @MainActor
    func testNotNowLeavesTheChoiceOnTheCirclePage() {
        let app = launch(["-fakeCircles", "empty", "-fakePushPermission", "notDetermined"])
        app.tabBars.buttons["Guilds"].tap()
        XCTAssertTrue(app.staticTexts["No Guilds yet"].waitForExistence(timeout: 10))
        create("Backyard Crew", in: app)
        let alert = app.alerts[explanation]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Not now"].tap()
        open("Backyard Crew", in: app)
        scrollToSettings(app)
        XCTAssertTrue(app.buttons["Turn on notifications"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testACircleAndAFriendCanBeMuted() {
        let app = launch(["-fakeCircles", "some", "-autoScreen", "circle", "-fakePushPermission", "authorized"])
        let mute = app.switches["Mute this Guild"]
        app.openGuildInfo()
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<24 where !mute.exists { list.swipeUp() }
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        mute.switches.firstMatch.tap()
        // The switch's value says it took. Its footer can be off the bottom of the list, out of the accessibility tree, when the
        // swiping stopped with the row low on the screen, so it's scrolled to before it's read.
        let muted = NSPredicate(format: "value == '1'")
        expectation(for: muted, evaluatedWith: mute)
        waitForExpectations(timeout: 5)
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Muted: this Guild'")).firstMatch
        for _ in 0..<6 where !footer.waitForExistence(timeout: 1) { list.swipeUp() }
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")

        let maya = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maya Ortiz'")).firstMatch
        let mayaRow = maya.exists ? maya : app.staticTexts["Maya Ortiz"].firstMatch
        for _ in 0..<6 where !mayaRow.isHittable { list.swipeDown() }
        mayaRow.press(forDuration: 1.0)
        let muteMaya = app.buttons["Mute Maya Ortiz"]
        XCTAssertTrue(muteMaya.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        muteMaya.tap()
        XCTAssertTrue(app.images["Muted"].waitForExistence(timeout: 5) || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Muted'")).firstMatch.exists,
                      "screen: \(app.debugDescription.prefix(3000))")
    }
}
#endif
