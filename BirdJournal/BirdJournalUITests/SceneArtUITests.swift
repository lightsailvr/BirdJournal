import XCTest

// Debug only: asking for scene art needs the account (`ACCOUNTS_ENABLED`, issue #88), and the art server fake is DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Scene art on the card (issue #68) with real taps, over the seeded journal's newest card (a House Finch with a
/// glasses photo), the debug art states (`-autoArt`) and the in-memory art server (`-fakeArt`).
final class SceneArtUITests: XCTestCase {
    private static let pendingLine = "Your encounter is saved. Artwork is on its way."
    private static let failedLine = "The artwork couldn't be painted this time."

    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "card"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 15), "the card did not open; screen: \(app.debugDescription.prefix(3000))")
        return app
    }

    @MainActor
    private func status(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "card-art-status").firstMatch }

    @MainActor
    private func tap(_ button: XCUIElement, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(button); screen: \(app.debugDescription.prefix(4000))", file: file, line: line)
        if !button.isHittable { app.swipeUp() }
        button.tap()
    }

    @MainActor
    func testAPaintedCardOffersTryAgainAndUsePackArtAndTheLastArtStaysWhilePending() {
        let app = launch(["-autoArt", "ready", "-fakeAccount", "signedIn", "-fakeArt", "pending"])
        XCTAssertEqual(app.buttons["card-art"].label, "Card art: AI illustration")
        XCTAssertFalse(status(app).exists)

        tap(app.buttons["card-art-use-pack"], app)
        XCTAssertTrue(app.buttons["card-art-use-painted"].waitForExistence(timeout: 5))
        tap(app.buttons["card-art-use-painted"], app)
        XCTAssertTrue(app.buttons["card-art-use-pack"].waitForExistence(timeout: 5))

        // The painting machine is off: the card says its art is on its way and keeps the painting it has.
        tap(app.buttons["card-art-try-again"], app)
        XCTAssertTrue(status(app).waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(status(app).label, Self.pendingLine)
        XCTAssertEqual(app.buttons["card-art"].label, "Card art: AI illustration")
        XCTAssertFalse(app.buttons["card-art-try-again"].exists, "no second job while one is pending")
    }

    @MainActor
    func testAFailedJobOffersRetryArtWhichPaintsTheSameCard() {
        let app = launch(["-autoArt", "failed", "-fakeAccount", "signedIn", "-fakeArt", "paints"])
        XCTAssertTrue(status(app).waitForExistence(timeout: 5))
        XCTAssertEqual(status(app).label, Self.failedLine)

        tap(app.buttons["card-art-retry"], app)
        XCTAssertTrue(app.buttons["card-art-try-again"].waitForExistence(timeout: 15), "the retry did not paint; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(status(app).exists)
        XCTAssertEqual(app.buttons["card-art"].label, "Card art: AI illustration")
        // Still one card: the stepper over the House Finch's cards counts the same two.
        XCTAssertEqual(app.staticTexts["card-position"].label, "Card 1 of 2")
    }

    @MainActor
    func testKeepCurrentArtDismissesTheFailure() {
        let app = launch(["-autoArt", "failed", "-fakeAccount", "signedIn", "-fakeArt", "fails"])
        tap(app.buttons["card-art-keep"], app)
        XCTAssertFalse(status(app).waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["card-art-retry"].exists)
    }

    @MainActor
    func testSignedOutAPaintedCardStillSwitchesToPackArtButCantAskAgain() {
        let app = launch(["-autoArt", "ready", "-fakeAccount", "signedOut"])
        XCTAssertTrue(app.buttons["card-art-use-pack"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["card-art-try-again"].exists)
    }

    @MainActor
    func testAPendingCardSaysItsArtIsOnItsWay() {
        let app = launch(["-autoArt", "pending", "-fakeAccount", "signedIn", "-fakeArt", "pending"])
        XCTAssertTrue(status(app).waitForExistence(timeout: 5))
        XCTAssertEqual(status(app).label, Self.pendingLine)
    }
}

#endif
