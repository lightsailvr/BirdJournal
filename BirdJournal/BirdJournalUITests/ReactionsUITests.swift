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

    /// Finds land above the row the reader is on, by a push: it stays where it is, and a tap lands on what it's aimed at (issue #150).
    /// The reader's on the feed's first row, where a find lands right above them: further down, the system holds the rows by itself,
    /// so a row further down proves nothing. Without `.scrollPosition` this row slides down by a row's height, 191 pt.
    @MainActor
    private func assertRowHoldsStill(lateFinds: Int, screen: String = "circle", restingAt y: CGFloat = 140, file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(["-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", screen, "-fakeLateFinds", "\(lateFinds)", "-fakeLateFindsAfter", "30"])
        let sams = "00000000-0000-4000-8000-000000000003"
        let row = app.buttons["find-\(sams)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        // A slow drag, so it comes to rest where it's let go.
        for _ in 0..<10 where row.frame.minY > y {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(
                forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.3
            )
        }
        Thread.sleep(forTimeInterval: 1)
        let landed = app.staticTexts["late-finds-landed"]
        XCTAssertFalse(landed.exists, "they landed before there was anything to compare", file: file, line: line)
        let before = row.frame.minY
        XCTAssertTrue(landed.waitForExistence(timeout: 90), "they never landed", file: file, line: line)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(row.frame.minY, before, accuracy: 2, "the row moved under the reader", file: file, line: line)
        let lovely = app.buttons["react-lovely-\(sams)"]
        lovely.tap()
        XCTAssertTrue(lovely.wait(for: \.isSelected, toEqual: true, timeout: 5), "the tap landed elsewhere", file: file, line: line)

        // They did land, above.
        XCTAssertTrue(app.buttons["find-late-0"].exists || app.buttons["find-late-\(lateFinds - 1)"].exists, "no late find near; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
    }

    @MainActor
    func testOneLateFindLeavesTheRowWhereItIs() {
        assertRowHoldsStill(lateFinds: 1)
    }

    @MainActor
    func testALateFindLeavesARowPartWayUpThePageWhereItIs() {
        assertRowHoldsStill(lateFinds: 1, restingAt: 300)
    }

    @MainActor
    func testFifteenLateFindsLeaveTheRowWhereItIs() {
        assertRowHoldsStill(lateFinds: 15)
    }

    /// More than a page's worth: the refresh reads a second page to meet what's been read.
    @MainActor
    func testTwentyFiveLateFindsLeaveTheRowWhereItIs() {
        assertRowHoldsStill(lateFinds: 25)
    }

    /// On the feed across Guilds, too.
    @MainActor
    func testALateFindLeavesARowOnTheTabWhereItIs() {
        assertRowHoldsStill(lateFinds: 1, screen: "circles")
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Maya has, you haven'")).firstMatch.exists)
        screenshot(app, "64-compare")
    }
}
#endif
