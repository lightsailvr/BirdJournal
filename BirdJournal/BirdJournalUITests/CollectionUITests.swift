import XCTest

/// Issues #117 and #134: the board opens on the set you're in, your patches first and then the patterns; a patch's page hides
/// the tab bar; and coming back to Collection finds its mode, its board and each mode's scroll position as they were left.
/// Real taps on the seeded journal: three birds in Los Angeles, and two outside every set.
final class CollectionUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "cards"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testTheBoardShowsYourPatchesThenThePatternsEachInCollectorOrder() throws {
        let app = launch()
        let sewn = app.buttons.matching(identifier: "board-patch")
        XCTAssertTrue(sewn.firstMatch.waitForExistence(timeout: 15), "no patches on the board; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(sewn.count, 3, "the three birds found in Los Angeles; screen: \(app.debugDescription.prefix(4000))")
        let numbers = sewn.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(numbers.contains { $0.hasPrefix("House Finch, Citrus edition patch, seen 2 times") }, "\(numbers)")
        let first = app.buttons.matching(identifier: "board-pattern").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "no board; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(first.label.hasPrefix("Canada Goose, number 1 of 160, not yet found"), first.label)

        // A pattern is a way to the bird's profile in the Atlas.
        first.tap()
        XCTAssertTrue(app.buttons["profile-your-cards"].waitForExistence(timeout: 10), "the profile did not open; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testASearchReadsEveryBoardAndKeepsWhatMatches() throws {
        let app = launch(["-autoQuery", "House Finch"])
        let finch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, Citrus edition patch, seen 2 times'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Canada Goose'")).firstMatch.exists, "the search kept only the match")
    }

    @MainActor
    func testASearchWithNoMatchSaysSo() throws {
        let app = launch(["-autoQuery", "Dodo"])
        XCTAssertTrue(app.descendants(matching: .any)["no-search-match"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testAPatchPageHidesTheTabBarAndCollectionComesBackAsLeft() throws {
        let app = launch()
        let collectionTab = app.tabBars.buttons["Collection"]
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 15), "no Collection tab; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(collectionTab.isSelected)
        XCTAssertTrue(app.navigationBars["Collection"].waitForExistence(timeout: 10))

        // A patch's page: it gets the whole height, no tab bar over it. Back: the tab bar returns.
        let dove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mourning Dove, Citrus edition patch'")).firstMatch
        XCTAssertTrue(dove.waitForExistence(timeout: 10), "no dove patch; screen: \(app.debugDescription.prefix(3000))")
        dove.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.tabBars.firstMatch.exists && collectionTab.isHittable, "the tab bar shows on a patch's page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 10))
        XCTAssertTrue(collectionTab.isHittable, "no tab bar after closing the patch")

        // Down the board among the patterns, to one clear of the floating tab bar; its bird's page and back: the board is
        // where it was.
        for _ in 0..<3 { app.swipeUp() }
        let patterns = app.buttons.matching(identifier: "board-pattern").allElementsBoundByIndex
        let shown = try XCTUnwrap(patterns.first { Self.isClearOfBars($0, in: app) }, "no pattern in view; screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let scrolledTo = Self.settledMinY(of: tile)
        tile.tap()
        XCTAssertTrue(app.buttons["profile-your-cards"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(Self.settledMinY(of: tile), scrolledTo, accuracy: 4, "the board did not keep its scroll position")

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

        // Patches again: where the board was left, not the top.
        modes.buttons["Patches"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        let settled = NSPredicate { _, _ in Self.isClearOfBars(tile, in: app) }
        wait(for: [expectation(for: settled, evaluatedWith: tile)], timeout: 5)
        XCTAssertEqual(Self.settledMinY(of: tile), scrolledTo, accuracy: 12, "Patches did not keep its own scroll position")

        // Another board, chosen and kept across the tabs.
        let boards = app.navigationBars["Collection"].buttons["Board"]
        XCTAssertTrue(boards.waitForExistence(timeout: 5), "no board menu; screen: \(app.debugDescription.prefix(3000))")
        boards.tap()
        let uncharted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch
        XCTAssertTrue(uncharted.waitForExistence(timeout: 5), "no board list; screen: \(app.debugDescription.prefix(3000))")
        uncharted.tap()
        let blackbird = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Common Blackbird, Uncharted patch'")).firstMatch
        XCTAssertTrue(blackbird.waitForExistence(timeout: 5), "the Uncharted board did not show; screen: \(app.debugDescription.prefix(3000))")
        app.tabBars.buttons["Atlas"].tap()
        collectionTab.tap()
        XCTAssertTrue(blackbird.waitForExistence(timeout: 10), "Collection did not keep its board")
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
