import XCTest

/// Issue #52: the card's two faces and the real flip, with real taps on the seeded journal. The art button marks the
/// front, the "Encounter story" heading the back, and the Flip control's value names the face that is up. XCUITest's
/// tree also lists the hidden face (it shows elements SwiftUI hides from VoiceOver), so that only one face reaches
/// VoiceOver is checked by `CardFlipAccessibilityTests` in the app tests.
final class CardFlipUITests: XCTestCase {
    @MainActor
    private func launch(_ screen: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", screen] + extra
        app.launch()
        return app
    }

    @MainActor
    private func front(_ app: XCUIApplication) -> XCUIElement { app.buttons["card-art"] }
    @MainActor
    private func back(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["Encounter story"] }
    @MainActor
    private func flip(_ app: XCUIApplication) -> XCUIElement { app.buttons["card-flip"] }
    @MainActor
    private func newestCard(_ app: XCUIApplication) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch'")).firstMatch }

    /// The face that is up, and the control naming it.
    @MainActor
    private func assertShowing(back showsBack: Bool, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let shown = showsBack ? back(app) : front(app)
        XCTAssertTrue(shown.waitForExistence(timeout: 5), "the \(showsBack ? "back" : "front") is not up; screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        XCTAssertEqual(flip(app).value as? String, showsBack ? "Back" : "Front", file: file, line: line)
        XCTAssertEqual(flip(app).label, showsBack ? "Flip to artwork" : "Flip to encounter story", file: file, line: line)
    }

    @MainActor
    func testTheArtAndTheFlipControlTurnTheCardOneFaceAtATime() {
        let app = launch("card")
        XCTAssertTrue(flip(app).waitForExistence(timeout: 15), "the card did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.otherElements["card-rotates"].exists, "without Reduce Motion the card turns")
        assertShowing(back: false, app)

        front(app).tap()
        assertShowing(back: true, app)
        flip(app).tap()
        assertShowing(back: false, app)
        flip(app).tap()
        assertShowing(back: true, app)
    }

    @MainActor
    func testRapidTapsLandOnOneFace() {
        let app = launch("card")
        XCTAssertTrue(flip(app).waitForExistence(timeout: 15))
        for _ in 0..<3 { flip(app).tap() }
        assertShowing(back: true, app)
        for _ in 0..<4 { flip(app).tap() }
        assertShowing(back: true, app)
        flip(app).tap()
        assertShowing(back: false, app)
    }

    @MainActor
    func testViewOriginalPhotoOpensThePhotoWithoutFlipping() {
        let app = launch("card-back")
        XCTAssertTrue(back(app).waitForExistence(timeout: 15), "no back; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Photo attached"].exists)
        let view = app.buttons["View original photo"]
        if !view.isHittable { app.swipeUp() }
        view.tap()
        XCTAssertTrue(app.navigationBars["Original photo"].waitForExistence(timeout: 5), "the photo did not open; screen: \(app.debugDescription.prefix(4000))")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Original photo"].waitForExistence(timeout: 2))
        assertShowing(back: true, app)
    }

    @MainActor
    func testHeardIsTheDefaultAndSeenPersists() {
        let app = launch("card-back")
        XCTAssertTrue(back(app).waitForExistence(timeout: 15))
        let heard = app.buttons["Heard"]
        let seen = app.buttons["Seen"]
        XCTAssertTrue(heard.isSelected, "every card starts as Heard")
        seen.tap()
        XCTAssertTrue(seen.isSelected)
        assertShowing(back: true, app)

        // Back to the Cards view and in again: the card opens front up, reading Seen, and its back still says so.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch' AND label CONTAINS 'Seen'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the card in the collection does not read Seen; screen: \(app.debugDescription.prefix(4000))")
        tile.tap()
        assertShowing(back: false, app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '· Seen'")).firstMatch.exists)
        flip(app).tap()
        XCTAssertTrue(app.buttons["Seen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Seen"].isSelected)
    }

    @MainActor
    func testReduceMotionSwitchesFacesWithoutTurning() {
        let app = launch("card", ["-reduceMotion", "YES"])
        XCTAssertTrue(flip(app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["card-switches"].exists, "with Reduce Motion the card switches faces; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.otherElements["card-rotates"].exists)
        flip(app).tap()
        assertShowing(back: true, app)
        flip(app).tap()
        assertShowing(back: false, app)
    }

    @MainActor
    func testMissingPlaceRarityArtAndPhotoSaySo() {
        let app = launch("cards")
        XCTAssertTrue(newestCard(app).waitForExistence(timeout: 15), "no cards; screen: \(app.debugDescription.prefix(3000))")
        // The oldest seed: a Common Blackbird no pack describes, added with no location and no photo.
        let blackbird = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Common Blackbird'")).firstMatch
        for _ in 0..<4 where !blackbird.isHittable { app.swipeUp() }
        XCTAssertTrue(blackbird.waitForExistence(timeout: 15), "no blackbird card; screen: \(app.debugDescription.prefix(3000))")
        blackbird.tap()
        XCTAssertTrue(flip(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Place not recorded"].exists, "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Rarity unavailable for this place and season"].exists)
        XCTAssertEqual(front(app).label, "Card art: No art yet")

        flip(app).tap()
        assertShowing(back: true, app)
        XCTAssertTrue(app.staticTexts["No photo attached"].exists)
        XCTAssertFalse(app.buttons["View original photo"].exists, "no original, no entry")
        XCTAssertTrue(app.staticTexts["No art yet: no photo of this sighting, and no pack photo of this bird."].exists)
        XCTAssertTrue(app.staticTexts["Rarity unavailable for this place and season. No location was saved with this sighting, and rarity is never guessed."].exists)
    }

    @MainActor
    func testAReferencePhotoIsLabelledAsOne() {
        let app = launch("cards")
        XCTAssertTrue(newestCard(app).waitForExistence(timeout: 15), "no cards; screen: \(app.debugDescription.prefix(3000))")
        // The Mourning Dove was added from the phone: no photo of its own, so its art is the pack's reference photo.
        let dove = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mourning Dove'")).firstMatch
        for _ in 0..<4 where !dove.isHittable { app.swipeUp() }
        XCTAssertTrue(dove.waitForExistence(timeout: 15))
        dove.tap()
        XCTAssertTrue(flip(app).waitForExistence(timeout: 10))
        XCTAssertEqual(front(app).label, "Card art: Reference photo")
        flip(app).tap()
        assertShowing(back: true, app)
        XCTAssertTrue(app.staticTexts["No photo attached"].exists, "a reference photo is not the birder's photo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'A reference photo from your bird pack, not your bird.'")).firstMatch.exists)
    }
}
