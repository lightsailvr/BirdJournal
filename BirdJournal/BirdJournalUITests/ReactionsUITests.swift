import XCTest

// Debug only, like the circles: the account is off in Release (`ACCOUNTS_ENABLED`, issue #88) and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Reactions and Compare birds (issue #64) over the debug fake circle server: real taps give and take back a reaction
/// on a friend's find, the birder's own find has nothing to tap, and Compare birds sets the two side by side.
final class ReactionsUITests: XCTestCase {
    private static let mayasPhoebe = "00000000-0000-4000-8000-000000000000"

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES"] + arguments
        app.launch()
        return app
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAReactionIsGivenAndTakenBack() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let lovely = app.buttons["react-lovely-\(Self.mayasPhoebe)"]
        // Maya's Black Phoebe is the fourth find: scroll to it.
        app.scrolledTo(lovely, limit: 24)
        XCTAssertTrue(lovely.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(lovely.value as? String, "2 reactions", "Jo's and Sam's, seeded")
        // A real target for a thumb, whatever the pill looks like (issue #150).
        XCTAssertGreaterThanOrEqual(lovely.frame.height, 44)
        XCTAssertFalse(lovely.isSelected)
        screenshot(app, "64-feed-reactions")
        // Three equal pills across the row (issue #150, G9), whatever their names' lengths.
        let together = app.buttons["react-together-\(Self.mayasPhoebe)"]
        let jealous = app.buttons["react-jealous-\(Self.mayasPhoebe)"]
        XCTAssertEqual(lovely.label, "Lovely find")
        XCTAssertEqual(jealous.label, "Jealous!")
        XCTAssertEqual(together.label, "Let's go together")
        XCTAssertEqual(lovely.frame.width, together.frame.width, accuracy: 1)
        XCTAssertEqual(lovely.frame.width, jealous.frame.width, accuracy: 1)

        lovely.tap()
        XCTAssertTrue(lovely.wait(for: \.isSelected, toEqual: true, timeout: 5))
        // A reaction stays on the feed: it isn't a way into the find.
        XCTAssertFalse(app.navigationBars["Maya's find"].exists)
        XCTAssertEqual(lovely.value as? String, "3 reactions")
        XCTAssertEqual(together.value as? String, "1 reaction")
        screenshot(app, "64-feed-reacted")

        lovely.tap()
        XCTAssertTrue(lovely.wait(for: \.isSelected, toEqual: false, timeout: 5))
        XCTAssertEqual(lovely.value as? String, "2 reactions")
        // Only the three fixed kinds, and nowhere to comment.
        let mayaButtons = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@ AND identifier BEGINSWITH 'react-'", Self.mayasPhoebe))
        XCTAssertEqual(mayaButtons.count, 3)
        XCTAssertEqual(app.textFields.count + app.textViews.count, 0)
    }

    /// A reaction that doesn't land goes back, and says so beside it rather than at the far end of the feed.
    @MainActor
    func testAFailedReactionSaysSoBesideIt() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-fakeReactionsFail", "YES", "-autoScreen", "circle"])
        let lovely = app.buttons["react-lovely-\(Self.mayasPhoebe)"]
        XCTAssertTrue(app.scrolledTo(lovely, limit: 24), "screen: \(app.debugDescription.prefix(3000))")
        lovely.tap()
        let error = app.descendants(matching: .any)["reaction-error-\(Self.mayasPhoebe)"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(error.label.contains("send your reaction"), error.label)
        XCTAssertEqual(error.frame.minY, lovely.frame.maxY, accuracy: 30, "beside the reaction")
        XCTAssertLessThan(error.frame.maxY, app.frame.height, "on screen")
        XCTAssertFalse(lovely.isSelected, "it goes back")
        XCTAssertEqual(lovely.value as? String, "2 reactions")
    }

    @MainActor
    func testComparingBirdsWithAFriend() {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-seedJournal", "YES", "-autoScreen", "circle"])
        let picker = app.segmentedControls["circlePageShowing"]
        XCTAssertTrue(app.buttons["Invite friends"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledTo(picker), "screen: \(app.debugDescription.prefix(3000))")
        picker.buttons["Compare birds"].tap()
        let maya = app.buttons["compareWith-maya"]
        XCTAssertTrue(maya.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<6 where !maya.isHittable { app.swipeUp() }
        XCTAssertFalse(app.buttons["compareWith-fake-sub"].exists, "never yourself")
        screenshot(app, "64-compare-friends")
        maya.tap()

        XCTAssertTrue(app.navigationBars["You and Maya"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        let woodpecker = app.descendants(matching: .any)["compare-Melanerpes formicivorus"]
        XCTAssertTrue(woodpecker.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(woodpecker.label, "Acorn Woodpecker. You: Not yet. Maya: Heard.")
        let phoebe = app.descendants(matching: .any)["compare-Sayornis nigricans"]
        XCTAssertTrue(phoebe.label.hasSuffix("Maya: Seen."), phoebe.label)
        XCTAssertTrue(app.staticTexts["Maya has these. Go find them."].exists)
        screenshot(app, "64-compare")
    }
}
#endif
