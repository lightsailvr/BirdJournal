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

    /// A list's rows sit on the raised surface, not the system's near-black (issue #150): measured from the screen, since
    /// the colour is what a birder sees and the view tree can't say.
    @MainActor
    func testSettingsRowsAreOnTheRaisedSurface() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-appearance", "dark", "-autoScreen", "settings"]
        app.launch()
        // By its words: a section's header is a cell too, on the page's colour.
        let row = app.cells.containing(NSPredicate(format: "label == 'Listen with'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let shot = XCUIScreen.main.screenshot()
        let cg = try XCTUnwrap(shot.image.cgImage)
        let scale = shot.image.scale
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Between "Listen with" and its value.
        let (x, y) = ((row.frame.minX + row.frame.width * 0.38) * scale, row.frame.midY * scale)
        context.draw(cg, in: CGRect(x: -x, y: y - CGFloat(cg.height) + 1, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        // The raised surface, #193A3D.
        for (channel, expected) in zip(pixel.prefix(3), [UInt8(0x19), 0x3A, 0x3D]) {
            XCTAssertLessThan(abs(Int(channel) - Int(expected)), 14, "the row is \(pixel.prefix(3))")
        }
    }

    /// The long explanation is a tap away, not gone (issue #150).
    @MainActor
    func testHowThisWorksOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "settings"]
        app.launch()
        let more = app.staticTexts["How this works"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let detail = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Featherguild registers with the Meta AI app'")).firstMatch
        XCTAssertFalse(detail.exists, "it starts closed")
        more.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
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

    /// The Circles tab (issue #61) needs the account, so it follows the same switch.
    @MainActor
    func testCirclesTabFollowsTheBuildSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Listen"].waitForExistence(timeout: 10), "no tab bar; screen: \(app.debugDescription.prefix(3000))")
        #if DEBUG
        XCTAssertTrue(app.tabBars.buttons["Guilds"].exists, "no Guilds tab in a Debug build")
        #else
        XCTAssertFalse(app.tabBars.buttons["Guilds"].exists, "a Guilds tab in a Release build")
        #endif
    }
}

private extension XCUIElement {
    func waitForSelected(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
