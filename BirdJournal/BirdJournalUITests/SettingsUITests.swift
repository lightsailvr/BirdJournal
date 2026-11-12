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
        let row = appIconRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no App icon row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()

        for title in ["Great Egret", "Red-tailed Hawk"] {
            let choice = app.buttons[title]
            XCTAssertTrue(choice.waitForExistence(timeout: 10))
            choice.tap()
            // The system's "You have changed the icon" alert belongs to SpringBoard.
            // Under load a tap on its button can come before it takes taps, and the check moves only once it's closed.
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.waitForExistence(timeout: 5) {
                for _ in 0..<10 where alert.exists {
                    alert.buttons.firstMatch.tap()
                    sleep(1)
                }
            }
            XCTAssertTrue(choice.waitForSelected(), "\(title) is not checked")
        }
    }
}

/// The "App icon" row of Settings, scrolled to. The Glasses section above it holds the photo-size choice since
/// 2026-11-12, which puts the row below the fold on a phone, and a row a lazy list has not reached does not exist.
@MainActor
private func appIconRow(in app: XCUIApplication) -> XCUIElement {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'App icon'")).firstMatch
    for _ in 0..<4 where !row.waitForExistence(timeout: 2) {
        app.swipeUp()
    }
    return row
}

/// The birds in glasses on the home screen (issue #150, slice 11). `TEST_RUNNER_BIRDJOURNAL_ICON_SHOTS=<folder>` also saves what each
/// looks like there, which is the evidence for how an icon reads at that size.
final class AppIconHomeScreenUITests: XCTestCase {
    private let birds = ["Red-tailed Hawk", "Blue Bird", "Great Egret", "House Finch", "Prothonotary Warbler", "Steller's Jay"]

    @MainActor
    private func openIcons(_ app: XCUIApplication) {
        app.launchArguments = ["-inMemoryAlbum", "YES"]
        app.launch()
        app.buttons["Settings"].tap()
        let row = appIconRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no App icon row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
    }

    private func choose(_ title: String, in app: XCUIApplication) {
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "no \(title); screen: \(app.debugDescription.prefix(3000))")
        guard !choice.isSelected else { return }
        choice.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 5) { alert.buttons.firstMatch.tap() }
        XCTAssertTrue(choice.waitForSelected(), "\(title) is not checked")
    }

    @MainActor
    func testEachBirdReachesTheHomeScreenAndAChoiceSurvivesARelaunch() throws {
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let folder = ProcessInfo.processInfo.environment["BIRDJOURNAL_ICON_SHOTS"]
        var pictures = Set<Data>()
        openIcons(app)
        for bird in birds {
            choose(bird, in: app)
            XCUIDevice.shared.press(.home)
            // The app's icon, not its widget (issue #150), which goes by the same name on a simulator that has one.
            let icon = springboard.icons.matching(NSPredicate(format: "label == 'Featherguild' AND NOT (value == 'Widget')")).firstMatch
            XCTAssertTrue(icon.waitForExistence(timeout: 10), "no icon on the home screen: \(springboard.debugDescription.prefix(2000))")
            for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); sleep(1) }
            XCTAssertTrue(icon.isHittable, "the icon is on no page reached: \(springboard.debugDescription.prefix(2000))")
            sleep(1)
            pictures.insert(icon.screenshot().pngRepresentation)
            if let folder {
                let name = bird.lowercased().replacing(" ", with: "-").replacing("'", with: "")
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: folder).appending(path: "home-\(name).png"))
            }
            app.activate()
            XCTAssertTrue(app.buttons[bird].waitForExistence(timeout: 10))
        }

        XCTAssertEqual(pictures.count, birds.count, "some choices left the same picture on the home screen")

        // The one chosen last is still the one chosen after the app starts again, as it is after an update: iOS keeps it by name.
        app.terminate()
        openIcons(app)
        XCTAssertTrue(app.buttons["Steller's Jay"].waitForSelected(), "the choice didn't survive")

        choose("Red-tailed Hawk", in: app)
    }
}

/// The account's build-time switch (issue #88): on in Debug, Settings has the Account row; off in Release, it has none.
/// The Release case runs in the `BirdJournal-Release` scheme (`scripts/build-and-test.sh --release`). The expectation
/// keys on DEBUG, not on the switch, so turning the account on in Release fails here until #71 updates this test.
final class AccountSwitchUITests: XCTestCase {
    @MainActor
    func testAccountRowFollowsTheBuildSwitch() {
        let app = XCUIApplication()
        // A Release build shows the "What's new" card unasked after an update; here it would come up over Settings.
        app.launchArguments = ["-inMemoryAlbum", "YES", "-whatsNew", "hide"]
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
        app.launchArguments = ["-inMemoryAlbum", "YES", "-whatsNew", "hide"]
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
