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
        XCTAssertTrue(element(app, "patch-count").label.hasPrefix("Seen once in Los Angeles, sewn "), element(app, "patch-count").label)
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Citrus edition, No. '")).firstMatch
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
        let boards = app.buttons["collection-board"]
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

    @MainActor
    func testSwipingMovesThroughEveryPatchAndLandsOnItsFace() {
        let app = launch("card")
        XCTAssertTrue(face(app).waitForExistence(timeout: 15), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(face(app).label.hasPrefix("House Finch"), face(app).label)
        XCTAssertTrue(app.patchPage("3 of 5").waitForExistence(timeout: 5), "dove, phoebe, finch, then the two Uncharted; screen: \(app.debugDescription.prefix(3000))")

        // From the patch: the next patch, the first Uncharted.
        app.swipeLeft()
        XCTAssertTrue(app.patchPage("4 of 5").waitForExistence(timeout: 5), "the swipe did not move on; screen: \(app.debugDescription.prefix(3000))")
        assertShowing(card: false, app)

        // From its card: back to the finch, on the finch's face.
        turn(app).tap()
        assertShowing(card: true, app)
        app.swipeRight()
        XCTAssertTrue(app.patchPage("3 of 5").waitForExistence(timeout: 5), "the swipe from the card did not move; screen: \(app.debugDescription.prefix(3000))")
        assertShowing(card: false, app)
        XCTAssertTrue(face(app).label.hasPrefix("House Finch"), face(app).label)

        // And coming back to the one turned over, it's the patch again.
        app.swipeLeft()
        XCTAssertTrue(app.patchPage("4 of 5").waitForExistence(timeout: 5))
        assertShowing(card: false, app)
    }

    @MainActor
    func testOnItsSideThePatchIsLeftAndItsCardRightWithNothingToTurn() throws {
        let app = launch("card")
        XCTAssertTrue(face(app).waitForExistence(timeout: 15), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }

        let all = app.buttons["card-all-sightings"]
        let patch = app.descendants(matching: .any)["patch-face"].firstMatch
        let predicate = NSPredicate { _, _ in patch.exists && all.exists && all.isHittable && patch.frame.maxX <= all.frame.minX + 20 }
        wait(for: [expectation(for: predicate, evaluatedWith: patch)], timeout: 10)
        XCTAssertLessThan(patch.frame.midX, all.frame.midX, "the patch on the left, its card on the right")
        XCTAssertFalse(turn(app).exists, "both faces show, so nothing turns")
        XCTAssertTrue(app.descendants(matching: .any)["card-back-scroll"].firstMatch.exists, "the card scrolls")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "patch-sideways"
        shot.lifetime = .keepAlways
        add(shot)

        // A swipe moves on from the patch, and from over the card, whose own scrolling is vertical.
        patch.swipeLeft()
        XCTAssertTrue(app.patchPage("4 of 5").waitForExistence(timeout: 5), "the swipe from the patch; screen: \(app.debugDescription.prefix(3000))")
        let cards = app.descendants(matching: .any).matching(identifier: "card-back-scroll").allElementsBoundByIndex
        let card = try XCTUnwrap(cards.first { $0.isHittable }, "no card in reach; screen: \(app.debugDescription.prefix(3000))")
        card.swipeRight()
        XCTAssertTrue(app.patchPage("3 of 5").waitForExistence(timeout: 5), "the swipe from over the card; screen: \(app.debugDescription.prefix(3000))")

        // And the page comes back upright with its Turn over.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(turn(app).waitForExistence(timeout: 10))
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

    /// Attaching a library photo to a sighting heard on the phone (#137). `-fakeLibraryPhoto` stands in for the system
    /// picker, which is out of XCUITest's reach: its button hands over a picture as the picker's item would.
    @MainActor
    func testAPhotoAttachedToASightingShowsOnItAndCanBeRemoved() {
        let app = launch("sighting", ["-autoCardSpecies", "Zenaida macroura", "-fakeLibraryPhoto", "YES"])
        let attach = app.buttons["sighting-attach-photo"]
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<8 where !attach.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["No photo attached"].exists, "a sighting heard on the phone has no photo of its own")
        XCTAssertFalse(app.buttons["View original photo"].exists)
        attach.tap()

        let photo = element(app, "sighting-attached-photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "the photo isn't on the sighting; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertGreaterThan(photo.frame.height, 50, "it shows at a size to see")
        XCTAssertTrue(app.staticTexts["Photo attached"].exists)
        XCTAssertFalse(attach.exists, "one photo at a time, so it is clear which one a share sends")
        XCTAssertTrue(app.buttons["Heard"].isSelected, "attaching a photo doesn't say the bird was seen")

        // The photo takes no touches of its own: the controls under it still get theirs.
        let view = app.buttons["View original photo"]
        for _ in 0..<4 where !view.isHittable { app.swipeUp() }
        view.tap()
        XCTAssertTrue(app.navigationBars["Original photo"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.images["Original photo"].waitForExistence(timeout: 5), "the stored file opens")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Original photo"].waitForExistence(timeout: 2))

        let remove = app.buttons["sighting-remove-photo"]
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        remove.tap()
        let confirm = app.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        confirm.tap()
        XCTAssertTrue(attach.waitForExistence(timeout: 5), "it can be attached again; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(photo.exists)
        XCTAssertTrue(app.staticTexts["No photo attached"].exists)
    }

    /// The real picker's button, not the stand-in: the sheet is the system's and out of reach, but the control is there
    /// and takes the tap.
    @MainActor
    func testTheAttachActionIsThereWithoutTheStandIn() {
        let app = launch("sighting", ["-autoCardSpecies", "Zenaida macroura"])
        let attach = app.buttons["sighting-attach-photo"]
        XCTAssertTrue(app.staticTexts["Your note"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<8 where !attach.isHittable { app.swipeUp() }
        XCTAssertTrue(attach.isHittable, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(attach.label, "Attach a photo")
    }
}

private extension XCUIApplication {
    /// A patch's page by its position: its title also names the place, "Los Angeles, 3 of 5" (issue #150).
    func patchPage(_ position: String) -> XCUIElement {
        navigationBars.matching(NSPredicate(format: "identifier ENDSWITH %@", ", \(position)")).firstMatch
    }
}
