import XCTest

/// Issue #53: a species gallery of fifteen seeded House Finch cards at two places (`-seedGallery`). Real taps filter it
/// by place, open a card, step through the filtered cards with Next and Previous (each disabled at its end), and come
/// back to the gallery with the filter and the last card shown as they were left. The place's name comes from reverse
/// geocoding, or the coordinate offline, so the test picks the place by its count of six.
final class GalleryUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedGallery", "YES", "-collectionIntroShown", "YES", "-autoScreen", "gallery"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func tiles(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(identifier: "gallery-tile") }

    /// Filters the gallery to the place with six cards and returns that place's name.
    @MainActor
    private func filterToSixCardPlace(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String {
        let title = app.staticTexts["gallery-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "no gallery; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        XCTAssertEqual(title.label, "House Finch · 15 cards · 2 places", file: file, line: line)
        XCTAssertEqual(app.staticTexts["gallery-count"].label, "15 cards", file: file, line: line)

        app.buttons["gallery-place"].tap()
        let place = app.buttons.matching(NSPredicate(format: "label ENDSWITH ' · 6'")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 5), "no place with six cards; screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        let name = String(place.label.dropLast(" · 6".count))
        place.tap()
        XCTAssertTrue(app.staticTexts["gallery-count"].waitForLabel("6 of 15 cards", timeout: 5), "the filter did not apply; screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        XCTAssertEqual(app.buttons["gallery-place"].value as? String, name, file: file, line: line)
        return name
    }

    @MainActor
    func testFilterStepThroughCardsAndBackRestoresTheFilterAndTheCard() throws {
        let app = launch()
        let place = filterToSixCardPlace(app)
        let tile = tiles(app).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertTrue(tile.label.hasPrefix(place), "the tile names its place first: \(tile.label)")
        let thirdTile = tiles(app).element(boundBy: 2).label
        tile.tap()

        let position = app.staticTexts["card-position"]
        let previous = app.buttons["card-previous"]
        let next = app.buttons["card-next"]
        XCTAssertTrue(position.waitForExistence(timeout: 10), "the card did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(position.label, "Card 1 of 6", "the position counts within the filter")
        XCTAssertFalse(previous.isEnabled, "the first card has no previous")
        XCTAssertTrue(next.isEnabled)

        next.tap()
        XCTAssertTrue(position.waitForLabel("Card 2 of 6", timeout: 5), "Next did not step; \(position.label)")
        previous.tap()
        XCTAssertTrue(position.waitForLabel("Card 1 of 6", timeout: 5), "Previous did not step back; \(position.label)")
        for _ in 0..<5 { next.tap() }
        XCTAssertTrue(position.waitForLabel("Card 6 of 6", timeout: 5))
        XCTAssertFalse(next.isEnabled, "the last card has no next")
        XCTAssertTrue(previous.isEnabled)
        for _ in 0..<3 { previous.tap() }
        XCTAssertTrue(position.waitForLabel("Card 3 of 6", timeout: 5))

        // A different card opens on its front.
        app.buttons["card-flip"].tap()
        XCTAssertEqual(app.buttons["card-flip"].value as? String, "Back")
        previous.tap()
        XCTAssertTrue(position.waitForLabel("Card 2 of 6", timeout: 5))
        XCTAssertEqual(app.buttons["card-flip"].value as? String, "Front", "another card opens front up")
        next.tap()
        XCTAssertTrue(position.waitForLabel("Card 3 of 6", timeout: 5))

        // Back: the filter as it was, and the card last shown marked.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["gallery-count"].waitForLabel("6 of 15 cards", timeout: 5), "Back lost the filter; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.buttons["gallery-place"].value as? String, place)
        let selected = tiles(app).matching(NSPredicate(format: "isSelected == true"))
        XCTAssertEqual(selected.count, 1, "one card marked as the last shown")
        XCTAssertEqual(selected.firstMatch.label, thirdTile, "the card last shown is the third of the filter")

        // All encounters from a card goes back to the same gallery too.
        tiles(app).firstMatch.tap()
        let all = app.buttons["card-all-encounters"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        if !all.isHittable { app.swipeUp() }
        all.tap()
        XCTAssertTrue(app.staticTexts["gallery-count"].waitForLabel("6 of 15 cards", timeout: 5), "All encounters lost the filter; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testAccessibilityTextSizesShowOneColumn() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let tile = tiles(app).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "no gallery; screen: \(app.debugDescription.prefix(3000))")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(tile.frame.width, window.width * 0.75, "a tile spans the page in one column: \(tile.frame) in \(window)")
    }
}
