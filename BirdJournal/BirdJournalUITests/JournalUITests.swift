import XCTest

/// The sighting detail's map card (issue #44): a real tap on it opens the full map sheet with its style picker.
final class JournalUITests: XCTestCase {
    @MainActor
    func testMapCardOpensTheFullMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-autoScreen", "sighting"]
        app.launch()

        let card = app.buttons["sighting-map-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "no map card; screen: \(app.debugDescription.prefix(3000))")
        // The card sits under the fact rows, where the floating tab bar covers its lower half on a small phone and
        // takes a tap at its centre, and a swipe up flings it under the navigation bar: tap a point of the card
        // that is clear of both bars.
        let window = app.windows.firstMatch.frame
        var clear = Self.visibleBand(of: card.frame, in: window)
        if clear == nil {
            app.swipeUp()
            clear = Self.visibleBand(of: card.frame, in: window)
        }
        let band = try XCTUnwrap(clear, "no part of the map card is clear of the bars; frame \(card.frame)")
        let frame = card.frame
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (band.midY - frame.minY) / frame.height)).tap()

        XCTAssertTrue(app.navigationBars["On the map"].waitForExistence(timeout: 10), "the map sheet did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Satellite"].exists)
        XCTAssertTrue(app.otherElements["sighting-map-callout"].waitForExistence(timeout: 5), "no callout for the opened sighting")
        app.buttons["Done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The part of `frame` below the navigation bar and above the floating tab bar, nil when none is.
    private static func visibleBand(of frame: CGRect, in window: CGRect) -> CGRect? {
        let band = frame.intersection(CGRect(x: window.minX, y: window.minY + 130, width: window.width, height: window.height - 130 - 140))
        return band.isNull || band.height < 20 ? nil : band
    }
}
