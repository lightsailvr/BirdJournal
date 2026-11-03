import XCTest

/// Issue #117 (design guide page 10): a card's page hides the tab bar, and coming back to Collection finds its mode,
/// its sort and each mode's scroll position as they were left. Real taps on the seeded journal: six cards, the oldest a
/// Common Blackbird at the foot of the grid.
final class CollectionUITests: XCTestCase {
    @MainActor
    func testCardPageHidesTheTabBarAndCollectionComesBackAsLeft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "cards"]
        app.launch()

        let collectionTab = app.tabBars.buttons["Collection"]
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 15), "no Collection tab; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(collectionTab.isSelected)
        XCTAssertTrue(app.navigationBars["Collection"].waitForExistence(timeout: 10))

        // Down to the oldest card, clear of the floating tab bar.
        let blackbird = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Common Blackbird'")).firstMatch
        XCTAssertTrue(blackbird.waitForExistence(timeout: 10), "no Common Blackbird card; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<6 where !Self.isClearOfBars(blackbird, in: app) { app.swipeUp() }
        XCTAssertTrue(Self.isClearOfBars(blackbird, in: app), "could not scroll to the oldest card; frame \(blackbird.frame)")
        let scrolledTo = Self.settledMinY(of: blackbird)

        // Its page: the card gets the whole height, no tab bar over it.
        blackbird.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the card did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.tabBars.firstMatch.exists && collectionTab.isHittable, "the tab bar shows on a card's page")

        // Back: the tab bar returns, and the grid is where it was.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 10))
        XCTAssertTrue(collectionTab.isHittable, "no tab bar after closing the card")
        XCTAssertTrue(blackbird.waitForExistence(timeout: 5))
        XCTAssertEqual(Self.settledMinY(of: blackbird), scrolledTo, accuracy: 4, "the grid did not keep its scroll position")

        // Another mode, another tab and back: the mode stays.
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the mode picker is not pinned in reach; screen: \(app.debugDescription.prefix(3000))")
        modes.buttons["Sightings"].tap()
        XCTAssertTrue(modes.buttons["Sightings"].isSelected)
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["Start listening"].waitForExistence(timeout: 10))
        collectionTab.tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 10))
        XCTAssertTrue(modes.buttons["Sightings"].isSelected, "Collection did not come back on Sightings")

        // Cards again: where the grid was left, not the top.
        modes.buttons["Cards"].tap()
        XCTAssertTrue(blackbird.waitForExistence(timeout: 5))
        let settled = NSPredicate { _, _ in Self.isClearOfBars(blackbird, in: app) }
        wait(for: [expectation(for: settled, evaluatedWith: blackbird)], timeout: 5)
        XCTAssertEqual(Self.settledMinY(of: blackbird), scrolledTo, accuracy: 12, "Cards did not keep its own scroll position")

        // The sort, chosen and kept across the tabs: oldest first puts the blackbird at the top, above the newer
        // Black Phoebe.
        let sort = app.navigationBars["Collection"].buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5), "no Sort in the Cards view; screen: \(app.debugDescription.prefix(3000))")
        sort.tap()
        let oldest = app.buttons["Oldest first"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "no sort menu; screen: \(app.debugDescription.prefix(3000))")
        oldest.tap()
        let phoebe = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Black Phoebe'")).firstMatch
        wait(for: [expectation(for: settled, evaluatedWith: blackbird)], timeout: 5)
        XCTAssertTrue(phoebe.exists)
        XCTAssertLessThan(blackbird.frame.minY, phoebe.frame.minY, "Oldest first did not put the oldest card first")
        app.tabBars.buttons["Atlas"].tap()
        collectionTab.tap()
        XCTAssertTrue(blackbird.waitForExistence(timeout: 10))
        XCTAssertTrue(Self.isClearOfBars(blackbird, in: app), "Collection did not come back where it was left")
        XCTAssertLessThan(blackbird.frame.minY, phoebe.frame.minY, "Collection did not keep its sort")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Where `element`'s top rests once the scroll view has stopped (a swipe to the foot of the grid bounces first).
    @MainActor
    private static func settledMinY(of element: XCUIElement) -> CGFloat {
        var last = element.frame.minY
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = element.frame.minY
            if abs(now - last) < 0.5 { return now }
            last = now
        }
        return last
    }

    /// Whether `element` is on screen below the navigation bar and above the floating tab bar.
    @MainActor
    private static func isClearOfBars(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return frame.minY > window.minY + 120 && frame.minY < window.maxY - 260 && element.isHittable
    }
}
