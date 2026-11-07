import XCTest

/// "Share this patch" (issue #66): the preview sheet's choices with their defaults, the card face as the system share,
/// and, with an account (Debug, `ACCOUNTS_ENABLED`), a card sent by hand to the circle chosen and shown there with its
/// note.
final class ShareCardUITests: XCTestCase {
    private func openSheet(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-autoScreen", "card", "-autoCardSpecies", "Sayornis nigricans"] + arguments
        app.launch()
        let share = app.navigationBars.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        share.tap()
        XCTAssertTrue(app.navigationBars["Share this patch"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        return app
    }

    @MainActor
    func testThePreviewSheetDefaultsAndTheCardImage() {
        let app = openSheet()
        XCTAssertTrue(app.descendants(matching: .any)["share-preview"].exists)
        let note = app.switches["share-note"]
        let city = app.switches["share-city"]
        XCTAssertEqual(note.value as? String, "0", "the note is off by default")
        XCTAssertEqual(city.value as? String, "1", "the city is on by default")
        XCTAssertTrue(app.buttons["share-system"].waitForExistence(timeout: 10), "the card face is ready to share")

        city.switches.firstMatch.tap()
        XCTAssertEqual(city.value as? String, "0")
        let explanation = app.staticTexts["share-place-explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(explanation.label.contains("No place goes with it"), explanation.label)
        XCTAssertTrue(app.buttons["share-system"].waitForExistence(timeout: 10), "rendered again without the place")
    }

    #if ACCOUNTS_ENABLED && DEBUG
    /// A sighting heard on the phone has no original photo to share until the birder attaches one (#137). `-fakeLibraryPhoto`
    /// stands in for the system picker.
    @MainActor
    func testAnAttachedPhotoIsWhatACardCanSend() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "sighting",
            "-autoCardSpecies", "Zenaida macroura", "-fakeLibraryPhoto", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "some",
        ]
        app.launch()
        let share = app.navigationBars.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        share.tap()
        let photo = app.switches["share-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(photo.isEnabled, "nothing to send yet")
        app.navigationBars["Share this patch"].buttons["Cancel"].tap()

        let attach = app.buttons["sighting-attach-photo"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<8 where !attach.isHittable { app.swipeUp() }
        attach.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sighting-attached-photo"].waitForExistence(timeout: 5))

        share.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(photo.isEnabled, "the attached photo can go")
        let sunday = app.switches["share-circle-Sunday Group"]
        XCTAssertTrue(sunday.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.swipeUp()
        sunday.switches.firstMatch.tap()
        photo.switches.firstMatch.tap()
        XCTAssertEqual(photo.value as? String, "1")
        app.buttons["share-send"].tap()
        // Sending prepares the stored file (faces blurred, metadata stripped), so it really was read from the store.
        let sent = app.descendants(matching: .any)["share-sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 20), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testACardSentByHandReachesOnlyTheCircleChosen() {
        let app = openSheet(["-fakeAccount", "signedIn", "-fakeCircles", "some"])
        let photo = app.switches["share-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(photo.value as? String, "0", "the original photo is off by default")
        let send = app.buttons["share-send"]
        XCTAssertFalse(send.isEnabled, "no Guild chosen yet")

        let sunday = app.switches["share-circle-Sunday Group"]
        XCTAssertTrue(sunday.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // The circles are below the card's preview: scroll them clear of the Send bar.
        app.swipeUp()
        sunday.switches.firstMatch.tap()
        app.switches["share-note"].switches.firstMatch.tap()
        photo.switches.firstMatch.tap()
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(sunday.value as? String, "1")
        XCTAssertEqual(send.label, "Send to 1 Guild")
        send.tap()
        let sent = app.descendants(matching: .any)["share-sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 20), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(sent.label.contains("Sunday Group"), sent.label)
        app.navigationBars["Share this patch"].buttons["Done"].tap()

        // A card's page hides the tab bar (issue #117): back to Collection first.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.buttons["Guilds"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        app.tabBars.buttons["Guilds"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sunday Group'")).firstMatch.tap()
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-' AND label CONTAINS 'by you'")).firstMatch
        // The goal card (issue #65) and the Recent finds | Compare birds picker (#64) sit above the feed, which the list
        // builds only once scrolled to.
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<16 where !mine.exists { app.swipeUp() }
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(mine.label.contains("Black Phoebe") && mine.label.contains("Tail dipping over the pond"), mine.label)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Family'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10))
        let elsewhere = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'find-' AND label CONTAINS 'by you'")).firstMatch
        // Scroll through Family's feed (the seeds leave it empty) first, so the absence below means the card isn't there,
        // not that the list hadn't built its row yet.
        for _ in 0..<8 where !elsewhere.exists { app.swipeUp() }
        XCTAssertFalse(elsewhere.waitForExistence(timeout: 3), "a card shared to Sunday Group alone isn't in Family")
    }
    #endif
}
