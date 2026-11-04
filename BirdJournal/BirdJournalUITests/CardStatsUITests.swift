import XCTest

/// Issues #55 and #134: the seeded House Finch's paper card carries its biology (in US units on the simulator's en_US
/// locale, the wingspan predicted), and the Credits name the three datasets. Screenshots of both faces are kept with the
/// result. The type line and the fuller natural history are on the bird's profile in the Atlas.
final class CardStatsUITests: XCTestCase {
    @MainActor
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", screen]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testThePaperCardShowsTheBiology() {
        let app = launch("card")
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 15), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        keepScreenshot("the patch")

        app.buttons["card-flip"].tap()
        let wingspan = element(app, "card-stat-wingspan")
        XCTAssertTrue(wingspan.waitForExistence(timeout: 5), "no biology; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(wingspan.label.hasPrefix("Wingspan about ") && wingspan.label.hasSuffix("inches, estimated from wing length"), wingspan.label)
        XCTAssertTrue(element(app, "card-stat-weight").label.hasSuffix(" ounces"), element(app, "card-stat-weight").label)
        XCTAssertEqual(element(app, "card-stat-diet").label, "Diet: mostly seeds")
        XCTAssertTrue(element(app, "card-stat-nest").label.hasPrefix("Nest:"), element(app, "card-stat-nest").label)
        XCTAssertTrue(element(app, "card-stat-clutch").label.hasPrefix("Clutch:"), element(app, "card-stat-clutch").label)
        XCTAssertTrue(element(app, "card-stat-size").label.hasPrefix("Size:"), element(app, "card-stat-size").label)
        keepScreenshot("the paper card with its biology")
    }

    @MainActor
    func testCreditsListTheThreeDatasets() {
        let app = launch("credits")
        XCTAssertTrue(app.staticTexts["Sources & credits"].waitForExistence(timeout: 15))
        // The list builds its rows as they scroll into view.
        for source in ["avonet", "birdbase", "wingspan"] {
            let row = element(app, "credits-stats-\(source)")
            for _ in 0..<6 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "no credit for \(source); screen: \(app.debugDescription.prefix(3000))")
        }
        XCTAssertTrue(app.links["License: CC BY 4.0"].firstMatch.exists)
        keepScreenshot("credits with the stats datasets")
    }
}
