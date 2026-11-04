import XCTest

/// Issues #117 and #134: the board opens on the set you're in and shows only your patches; a patch's page hides
/// the tab bar; and coming back to Collection finds its mode, its board and each mode's scroll position as they were left.
/// Real taps on the seeded journal: three birds in Los Angeles, and two outside every set (`-seedBoard`: 30, enough to scroll).
final class CollectionUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "cards"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testTheBoardShowsOnlyYourPatchesInCollectorOrder() throws {
        let app = launch()
        let sewn = app.buttons.matching(identifier: "board-patch")
        XCTAssertTrue(sewn.firstMatch.waitForExistence(timeout: 15), "no patches on the board; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(sewn.count, 3, "the three birds found in Los Angeles; screen: \(app.debugDescription.prefix(4000))")
        let names = sewn.allElementsBoundByIndex.map { $0.label.split(separator: ",").first.map(String.init) ?? "" }
        XCTAssertEqual(names, ["Mourning Dove", "Black Phoebe", "House Finch"], "collector order")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet found'")).firstMatch.exists, "a bird you haven't found has no patch")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Canada Goose'")).firstMatch.exists)
    }

    @MainActor
    func testASearchReadsEveryBoardAndKeepsWhatMatches() throws {
        let app = launch(["-autoQuery", "House Finch"])
        let finch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, Citrus edition patch, seen 2 times'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mourning Dove'")).firstMatch.exists, "the search kept only the match")
    }

    @MainActor
    func testASearchForABirdYouHaventFoundSaysSo() throws {
        let app = launch(["-autoQuery", "Canada Goose"])
        XCTAssertTrue(app.descendants(matching: .any)["no-search-match"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testAPatchPageHidesTheTabBarAndCollectionComesBackAsLeft() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES"])
        let collectionTab = app.tabBars.buttons["Collection"]
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 15), "no Collection tab; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(collectionTab.isSelected)
        XCTAssertTrue(app.navigationBars["Collection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 10), "no board; screen: \(app.debugDescription.prefix(3000))")

        // Down the board to a patch clear of the floating tab bar; its page has no tab bar, and back finds the board where
        // it was.
        for _ in 0..<2 { app.swipeUp() }
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let shown = try XCTUnwrap(tiles.first { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let scrolledTo = Self.settledMinY(of: tile)
        tile.tap()
        XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.tabBars.firstMatch.exists && collectionTab.isHittable, "the tab bar shows on a patch's page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 10))
        XCTAssertTrue(collectionTab.isHittable, "no tab bar after closing the patch")
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
    }

    @MainActor
    func testAnotherBoardIsChosenAndKeptAcrossTheTabs() throws {
        let app = launch()
        let collectionTab = app.tabBars.buttons["Collection"]
        let boards = app.navigationBars["Collection"].buttons["Board"]
        XCTAssertTrue(boards.waitForExistence(timeout: 15), "no board menu; screen: \(app.debugDescription.prefix(3000))")
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
