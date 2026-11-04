import XCTest

// Debug only: asking for photo art needs the account (`ACCOUNTS_ENABLED`, issue #88), and the art server fake is DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Photo art on the card (issue #69) with real taps, over the seeded journal's newest card (a Heard House Finch with a
/// glasses photo) and the in-memory art server (`-fakeArt`): the request with its species check, the comparison of the
/// original and the painting, Approve, Keep original and Try again, "N left today", and "Did you see it?".
final class PhotoArtUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "sighting", "-fakeAccount", "signedIn"] + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["House Finch"].waitForExistence(timeout: 15), "the sighting did not open; screen: \(app.debugDescription.prefix(3000))")
        return app
    }

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func tap(_ button: XCUIElement, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(button); screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        for _ in 0..<3 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    @MainActor
    private func cardArtLabel(_ app: XCUIApplication) -> String { app.descendants(matching: .any)["card-art"].label }

    @MainActor
    func testTheGlassesPhotoIsPaintedThenComparedAndApproved() {
        let app = launch(["-fakeArt", "paints"])
        // No art of its own yet: the pack's reference photo, labelled as one.
        for _ in 0..<4 where !element("card-art", app).isHittable { app.swipeUp() }
        XCTAssertEqual(cardArtLabel(app), "Card art: Reference photo")

        tap(app.buttons["card-photo-art"], app)
        tap(app.buttons["photo-art-glasses"], app)
        // The birder confirms the species: nothing checks it automatically.
        XCTAssertTrue(app.staticTexts["Is this bird a House Finch?"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        tap(app.buttons["photo-art-confirm"], app)

        // Painted, waiting beside its original; the card is unchanged until approved.
        tap(app.buttons["card-photo-art-review"], app)
        XCTAssertTrue(element("photo-art-original", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("photo-art-generated", app).exists)
        XCTAssertTrue(app.staticTexts["Your photo stays as it is, whatever you choose."].exists)
        XCTAssertTrue(app.buttons["photo-art-keep-original"].exists)
        XCTAssertTrue(app.buttons["photo-art-try-again"].exists)
        tap(app.buttons["photo-art-approve"], app)

        XCTAssertTrue(app.navigationBars["House Finch"].waitForExistence(timeout: 5))
        let embellished = NSPredicate(format: "label == %@", "Card art: AI-embellished from your photo")
        expectation(for: embellished, evaluatedWith: app.descendants(matching: .any)["card-art"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["card-photo-art-review"].exists)
        // Still one sighting: the patch counts the same two.
    }

    @MainActor
    func testKeepOriginalLetsThePaintingGoAndTheCardStaysAsItWas() {
        let app = launch(["-autoArt", "photo-preview", "-fakeArt", "paints"])
        XCTAssertTrue(element("card-photo-art-status", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("card-photo-art-status", app).label, "Your photo art is ready to review.")
        tap(app.buttons["card-photo-art-review"], app)
        tap(app.buttons["photo-art-keep-original"], app)
        XCTAssertTrue(app.buttons["card-photo-art"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["card-photo-art-review"].exists)
        // No art of its own yet: the pack's reference photo, labelled as one.
        for _ in 0..<4 where !element("card-art", app).isHittable { app.swipeUp() }
        XCTAssertEqual(cardArtLabel(app), "Card art: Reference photo")
    }

    @MainActor
    func testTryAgainPaintsAnotherWithinTheDaysAllowance() {
        let app = launch(["-autoArt", "photo-preview", "-fakeArt", "paints", "-fakeArtDaily", "5"])
        tap(app.buttons["card-photo-art-review"], app)
        XCTAssertTrue(element("photo-art-allowance", app).waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(element("photo-art-allowance", app).label, "5 left today")
        tap(app.buttons["photo-art-try-again"], app)
        tap(app.buttons["card-photo-art-review"], app)
        let four = NSPredicate(format: "label == %@", "4 left today")
        expectation(for: four, evaluatedWith: element("photo-art-allowance", app))
        waitForExpectations(timeout: 10)
        tap(app.buttons["photo-art-approve"], app)
        let embellished = NSPredicate(format: "label == %@", "Card art: AI-embellished from your photo")
        expectation(for: embellished, evaluatedWith: app.descendants(matching: .any)["card-art"])
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testWithTodaysPaintingsUsedUpNothingCanBeAskedFor() {
        let app = launch(["-fakeArt", "paints", "-fakeArtDaily", "0"])
        tap(app.buttons["card-photo-art"], app)
        XCTAssertTrue(element("photo-art-allowance", app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("photo-art-allowance", app).label, "0 left today")
        tap(app.buttons["photo-art-glasses"], app)
        XCTAssertTrue(app.buttons["photo-art-confirm"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photo-art-confirm"].isEnabled)
    }

    @MainActor
    func testAttachingALibraryPhotoToAHeardCardAsksDidYouSeeIt() {
        let app = launch(["-fakeArt", "pending", "-fakeLibraryPhoto", "YES"])
        XCTAssertTrue(app.buttons["Heard"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.buttons["Heard"].isSelected, "the newest sighting should start Heard")

        tap(app.buttons["card-photo-art"], app)
        tap(app.buttons["photo-art-library"], app)
        tap(app.buttons["photo-art-confirm"], app)
        let alert = app.alerts["Did you see it?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        alert.buttons["Yes, I saw it"].tap()

        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["Seen"])
        waitForExpectations(timeout: 5)
        // The painting machine is off: the photo waits to be painted, and the encounter is safe.
        XCTAssertEqual(element("card-photo-art-status", app).label, "Your photo is being painted. Your encounter is saved.")
    }

    @MainActor
    func testTheCardsOwnGlassesPhotoAsksNothing() {
        let app = launch(["-fakeArt", "pending"])
        tap(app.buttons["card-photo-art"], app)
        tap(app.buttons["photo-art-glasses"], app)
        tap(app.buttons["photo-art-confirm"], app)
        XCTAssertFalse(app.alerts["Did you see it?"].waitForExistence(timeout: 2))
        XCTAssertTrue(element("card-photo-art-status", app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testSignedOutThereIsNoPhotoArtToAskFor() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "sighting", "-fakeAccount", "signedOut"]
        app.launch()
        XCTAssertTrue(app.navigationBars["House Finch"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["card-photo-art"].exists)
    }
}

#endif
