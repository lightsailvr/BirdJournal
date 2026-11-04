import XCTest

/// Issue #134 (guide page 7): a species' patches across editions, with fifteen seeded House Finch sightings at two places
/// (`-seedGallery`). Real taps open a patch from the species view and the sightings behind them. The second place is San
/// Diego when the pack index has reached the phone, Uncharted when it hasn't, so the counts are what's checked.
final class GalleryUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedGallery", "YES", "-collectionIntroShown", "YES", "-autoScreen", "gallery"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func patches(_ app: XCUIApplication) -> XCUIElementQuery { app.buttons.matching(identifier: "board-patch") }

    @MainActor
    func testASpeciesShowsItsPatchesAcrossPlacesAndEachOpensItsPage() throws {
        let app = launch()
        let summary = app.staticTexts["species-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "no species view; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(summary.label.hasPrefix("2 patches · seen 15 times · since "), summary.label)
        XCTAssertEqual(patches(app).count, 2, "one patch per place; screen: \(app.debugDescription.prefix(4000))")

        // Los Angeles, as every label says the bird.
        let losAngeles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, Citrus edition patch, seen 9 times'")).firstMatch
        XCTAssertTrue(losAngeles.exists, "screen: \(app.debugDescription.prefix(4000))")
        losAngeles.tap()
        let turn = app.buttons["card-flip"]
        XCTAssertTrue(turn.waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.descendants(matching: .any)["patch-count"].label.hasPrefix("Seen 9 times in Los Angeles"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))

        // Every sighting of the bird.
        let all = app.buttons["species-all-sightings"]
        for _ in 0..<4 where !all.isHittable { app.swipeUp() }
        XCTAssertEqual(all.label, "All 15 sightings")
        all.tap()
        XCTAssertTrue(app.navigationBars["15 sightings"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testAccessibilityTextSizesShowOneColumn() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let patch = patches(app).firstMatch
        XCTAssertTrue(patch.waitForExistence(timeout: 15), "no species view; screen: \(app.debugDescription.prefix(3000))")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(patch.frame.width, window.width * 0.75, "a patch spans the page in one column: \(patch.frame) in \(window)")
    }
}
