import XCTest

/// Issue #55: the seeded House Finch card carries its type line and stats on the front (in US units on the
/// simulator's en_US locale, the wingspan predicted), its natural history on the back, and the Credits name the three
/// datasets. Screenshots of both faces are kept with the result.
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
    func testTheFrontShowsTheTypeLineAndStatsAndTheBackTheNaturalHistory() {
        let app = launch("card")
        let typeLine = element(app, "card-type-line")
        XCTAssertTrue(typeLine.waitForExistence(timeout: 15), "no type line; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(typeLine.label, "Type: Songbird, Finch")
        let wingspan = element(app, "card-stat-wingspan")
        XCTAssertTrue(wingspan.exists)
        XCTAssertTrue(wingspan.label.hasPrefix("Wingspan about ") && wingspan.label.hasSuffix("inches, estimated from wing length"), wingspan.label)
        XCTAssertTrue(element(app, "card-stat-weight").label.hasSuffix(" ounces"), element(app, "card-stat-weight").label)
        XCTAssertEqual(element(app, "card-stat-diet").label, "Diet: mostly seeds")
        app.swipeUp()
        keepScreenshot("card front with stats")

        app.buttons["card-flip"].tap()
        XCTAssertTrue(app.staticTexts["Encounter story"].waitForExistence(timeout: 5))
        let history = element(app, "card-natural-history")
        for _ in 0..<4 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.exists)
        for label in ["Habitat", "Migration", "Nest", "Clutch", "Lifestyle"] {
            XCTAssertTrue(app.staticTexts[label].exists, "no \(label) on the back")
        }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'From AVONET, BIRDBASE and the Avian wingspan database (CC BY 4.0)'")).firstMatch.exists)
        keepScreenshot("card back with natural history")
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
