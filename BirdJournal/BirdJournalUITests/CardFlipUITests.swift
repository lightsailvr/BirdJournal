import XCTest

/// Issue #134 (with #52's real flip): a patch and its paper card, with real taps on the seeded journal. The visible Turn
/// over control's value names the face that is up. XCUITest's tree also lists the hidden face (it shows elements SwiftUI
/// hides from VoiceOver), so that only one face reaches VoiceOver is checked by `CardFlipAccessibilityTests` and
/// `PaperCardAccessibilityTests` in the app tests.
final class CardFlipUITests: XCTestCase {
    @MainActor
    private func launch(_ screen: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", screen] + extra
        app.launch()
        return app
    }

    @MainActor
    private func face(_ app: XCUIApplication) -> XCUIElement { app.buttons["patch-face"] }
    @MainActor
    private func turn(_ app: XCUIApplication) -> XCUIElement { app.buttons["card-flip"] }
    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    /// The face that is up, by the control naming it.
    @MainActor
    private func assertShowing(card showsCard: Bool, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(turn(app).waitForExistence(timeout: 5), "no Turn over; screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        XCTAssertEqual(turn(app).value as? String, showsCard ? "Paper card" : "Patch", file: file, line: line)
        XCTAssertEqual(turn(app).label, showsCard ? "Turn back" : "Turn over", file: file, line: line)
    }

    @MainActor
    func testThePatchAndTurnOverTurnItOneFaceAtATime() {
        let app = launch("card")
        XCTAssertTrue(turn(app).waitForExistence(timeout: 15), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.otherElements["card-rotates"].exists, "without Reduce Motion the object turns")
        assertShowing(card: false, app)

        // A real tap on the patch itself, in the middle of the object.
        XCTAssertTrue(face(app).isHittable, "the patch takes the tap")
        face(app).tap()
        assertShowing(card: true, app)
        turn(app).tap()
        assertShowing(card: false, app)
        turn(app).tap()
        assertShowing(card: true, app)
    }

    @MainActor
    func testThePatchSaysWhatItIsInTypeBelowIt() {
        let app = launch("card", ["-autoCardSpecies", "Sayornis nigricans"])
        XCTAssertTrue(turn(app).waitForExistence(timeout: 15), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(turn(app).isHittable, "Turn over is visible and in reach")
        XCTAssertTrue(face(app).label.hasPrefix("Black Phoebe, Citrus edition patch, seen once, sewn "), face(app).label)
        XCTAssertEqual(face(app).value as? String ?? "", "")
        XCTAssertTrue(app.staticTexts["Black Phoebe"].exists)
        XCTAssertTrue(element(app, "patch-count").label.hasPrefix("Seen once in Los Angeles · sewn "), element(app, "patch-count").label)
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Citrus edition · No. '")).firstMatch
        XCTAssertTrue(line.exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Legendary'")).firstMatch.exists)
    }

    @MainActor
    func testTheCardCarriesTheStoryAndYourHistory() {
        let app = launch("card-back", ["-autoCardSpecies", "Haemorhous mexicanus"])
        assertShowing(card: true, app)
        XCTAssertEqual(element(app, "card-heading").label, "Citrus edition, number 130 of 160 in Los Angeles")
        XCTAssertEqual(element(app, "card-name").label, "House Finch")
        XCTAssertEqual(element(app, "card-story-title").label, "Painted by Its Berries")
        let excerpt = app.staticTexts["card-lore-excerpt"]
        XCTAssertTrue(excerpt.exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue([".", "!", "?"].contains(String(excerpt.label.last ?? " ")), "the excerpt ends a sentence: \(excerpt.label)")
        XCTAssertTrue(element(app, "card-history").label.hasPrefix("2 sightings here, sewn "), element(app, "card-history").label)
        XCTAssertEqual(app.buttons.matching(identifier: "card-history-sighting").count, 2, "the latest sightings; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(element(app, "card-art-credit").exists, "the footer says it's an AI illustration")
        XCTAssertEqual(element(app, "card-art-credit").label, "AI illustration")
    }

    @MainActor
    func testASightingOnTheCardOpensItsRecordAndComesBackToTheCard() {
        let app = launch("card-back", ["-autoCardSpecies", "Sayornis nigricans"])
        assertShowing(card: true, app)
        let row = app.buttons["card-history-sighting"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        for _ in 0..<4 where !row.isHittable { element(app, "card-back-scroll").swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 10), "the sighting did not open; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Heard"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertShowing(card: true, app)
    }

    @MainActor
    func testAllSightingsAndSourcesOpenFromTheFooter() {
        let app = launch("card-back", ["-autoCardSpecies", "Haemorhous mexicanus"])
        assertShowing(card: true, app)
        let all = app.buttons["card-all-sightings"]
        XCTAssertTrue(all.isHittable, "the footer stays in view; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(all.label.hasPrefix("All 2 sightings"), all.label)
        all.tap()
        XCTAssertTrue(app.navigationBars["2 sightings"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(app.buttons.matching(identifier: "patch-sighting").count, 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        assertShowing(card: true, app)
        app.buttons["card-sources"].tap()
        // The credits name what the patch is and what it was painted from.
        let patch = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'AI illustration, not a photograph: an embroidered patch'")).firstMatch
        for _ in 0..<12 where !patch.exists { app.swipeUp() }
        XCTAssertTrue(patch.exists, "no patch credit; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(patch.label.contains("from a reference photo ("), patch.label)
    }

    @MainActor
    func testRapidTapsLandOnOneFace() {
        let app = launch("card")
        XCTAssertTrue(turn(app).waitForExistence(timeout: 15))
        for _ in 0..<3 { turn(app).tap() }
        assertShowing(card: true, app)
        for _ in 0..<4 { turn(app).tap() }
        assertShowing(card: true, app)
        turn(app).tap()
        assertShowing(card: false, app)
    }

    @MainActor
    func testReduceMotionCrossFadesWithoutTurning() {
        let app = launch("card", ["-reduceMotion", "YES"])
        XCTAssertTrue(turn(app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["card-switches"].exists, "with Reduce Motion the faces cross-fade; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.otherElements["card-rotates"].exists)
        turn(app).tap()
        assertShowing(card: true, app)
        turn(app).tap()
        assertShowing(card: false, app)
    }

    @MainActor
    func testAnUnchartedPatchWithNoPackSaysSoPlainly() {
        let app = launch("cards")
        // The oldest seed: a Common Blackbird no pack describes, added with no location and no photo.
        let boards = app.navigationBars["Collection"].buttons["Board"]
        XCTAssertTrue(boards.waitForExistence(timeout: 15), "no board menu; screen: \(app.debugDescription.prefix(3000))")
        boards.tap()
        let uncharted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch
        XCTAssertTrue(uncharted.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        uncharted.tap()
        let blackbird = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Common Blackbird, Uncharted patch'")).firstMatch
        XCTAssertTrue(blackbird.waitForExistence(timeout: 10), "no blackbird patch; screen: \(app.debugDescription.prefix(3000))")
        blackbird.tap()
        XCTAssertTrue(turn(app).waitForExistence(timeout: 10))
        turn(app).tap()
        assertShowing(card: true, app)
        XCTAssertEqual(element(app, "card-heading").label, "Uncharted, outside every set")
        XCTAssertFalse(app.staticTexts["card-lore-excerpt"].exists, "no lore, no tale")
        XCTAssertFalse(element(app, "card-stats").exists, "no biology")
        XCTAssertFalse(element(app, "card-art-credit").exists, "no painting, so no AI illustration")
        XCTAssertFalse(app.buttons["card-sources"].exists, "no pack, no sources")

        // Its record says what's missing.
        let row = app.buttons["card-history-sighting"]
        XCTAssertTrue(row.label.contains("Place not recorded"), row.label)
        row.tap()
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 10))
        let rarity = app.staticTexts["Rarity unavailable for this place and season. No location was saved with this sighting, and rarity is never guessed."]
        for _ in 0..<6 where !rarity.exists { app.swipeUp() }
        XCTAssertTrue(rarity.exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["View original photo"].exists, "no original, no entry")
    }

    /// What the card's back used to hold about one sighting now lives on the sighting (issue #134).
    @MainActor
    func testHeardIsTheDefaultAndSeenPersists() {
        let app = launch("sighting")
        let heard = app.buttons["Heard"]
        let seen = app.buttons["Seen"]
        XCTAssertTrue(heard.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(heard.isSelected, "every sighting starts as Heard")
        seen.tap()
        XCTAssertTrue(seen.isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // In again through the patch's card: the row says Seen, and so does the record.
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "no House Finch patch; screen: \(app.debugDescription.prefix(4000))")
        tile.tap()
        XCTAssertTrue(turn(app).waitForExistence(timeout: 10))
        turn(app).tap()
        let row = app.buttons.matching(identifier: "card-history-sighting").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Seen"), row.label)
        row.tap()
        XCTAssertTrue(app.buttons["Seen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Seen"].isSelected)
    }

    @MainActor
    func testViewOriginalPhotoOpensThePhoto() {
        let app = launch("sighting")
        let view = app.buttons["View original photo"]
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<8 where !view.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Photo attached"].exists)
        view.tap()
        XCTAssertTrue(app.navigationBars["Original photo"].waitForExistence(timeout: 5), "the photo did not open; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Original photo"].waitForExistence(timeout: 2))
    }
}
