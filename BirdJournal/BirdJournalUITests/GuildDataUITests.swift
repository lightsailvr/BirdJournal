import XCTest

// Debug only, like the circles: the account is off in Release (`ACCOUNTS_ENABLED`, issue #88) and the fakes are DEBUG.
#if ACCOUNTS_ENABLED && DEBUG

/// Issue #150's Guild data, with real taps on the running app: Compare as boards, a goal's patches, the goal on Listen, and friends
/// on a set's rows and a paper card. Pictures clipped to a shape have taken touches that weren't theirs before, so each tap here
/// lands on a patch and checks where it went.
final class GuildDataUITests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedReferenceBirds", "YES", "-collectionIntroShown", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "reference"] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tapBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func testCompareShowsBoardsAndEveryPatchOpensItsOwnBird() {
        let app = launch(["-autoScreen", "compare"])
        XCTAssertTrue(app.navigationBars["You and Maya"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Maya has these. Go find them."].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["You both have"].exists)
        XCTAssertEqual(element(app, "compareTally").label, "You have 5, Maya has 5, and you both have 2.")

        // Three in a row, each opening its own bird.
        for (scientific, title) in [("Melanerpes formicivorus", "Acorn Woodpecker"), ("Ardea alba", "Great Egret"), ("Sialia mexicana", "Western Bluebird")] {
            let tile = app.buttons["compare-\(scientific)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5) && tile.isHittable, "\(scientific); screen: \(app.debugDescription.prefix(3000))")
            XCTAssertTrue(tile.label.contains("You: Not yet."), tile.label)
            tile.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8) || app.staticTexts[title].waitForExistence(timeout: 3), "\(title); screen: \(app.debugDescription.prefix(3000))")
            tapBack(app)
            XCTAssertTrue(app.navigationBars["You and Maya"].waitForExistence(timeout: 5))
        }

        // Near the edge of a column, a touch is still that tile's, on either side: a clipped picture next door doesn't take it.
        for (offset, title) in [(CGVector(dx: 0.04, dy: 0.3), "Western Bluebird"), (CGVector(dx: 0.96, dy: 0.3), "Western Bluebird")] {
            app.buttons["compare-Sialia mexicana"].coordinate(withNormalizedOffset: offset).tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8) && !app.staticTexts["Maya has these. Go find them."].exists, "screen: \(app.debugDescription.prefix(3000))")
            tapBack(app)
            XCTAssertTrue(app.navigationBars["You and Maya"].waitForExistence(timeout: 5))
        }

        // Heard or Seen stays, on the patch's caption and to VoiceOver.
        XCTAssertTrue(app.buttons["compare-Melanerpes formicivorus"].label.contains("Maya: Heard."))
        XCTAssertTrue(app.staticTexts["Heard by Maya"].exists)

        // Only yours opens your own patch.
        let only = app.buttons["compare-Zenaida macroura"]
        XCTAssertTrue(app.scrolledTo(only), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Only you"].exists)
        only.tap()
        XCTAssertTrue(element(app, "patch-face").waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAPatchWithoutItsPaintingIsStillATileThatOpens() {
        let app = launch(["-autoScreen", "compare", "-fakePatchArt", "missing"])
        let tile = app.buttons["compare-Ardea alba"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        tile.tap()
        XCTAssertTrue(app.staticTexts["Great Egret"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTheGoalsPatchesOpenTheirBirdsAndPlusNOpensTheBoard() {
        let app = launch(["-autoScreen", "circle"])
        let row = element(app, "goal-patches")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        let monthly = element(app, "goal-monthly")
        XCTAssertTrue(monthly.label.contains("12 of 14 species"), monthly.label)
        XCTAssertTrue(monthly.label.contains("birds, together."), monthly.label)

        // The newest of the month, as the fixture has it.
        let patches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'goal-patch-'"))
        XCTAssertGreaterThanOrEqual(patches.count, 6)
        let phoebe = app.buttons["goal-patch-Sayornis nigricans"]
        XCTAssertTrue(phoebe.isHittable, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(phoebe.label, "Black Phoebe, Citrus edition patch")
        phoebe.tap()
        XCTAssertTrue(app.staticTexts["Black Phoebe"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
        tapBack(app)
        // The next along opens its own bird, not its neighbour's.
        let hummingbird = app.buttons["goal-patch-Calypte anna"]
        XCTAssertTrue(hummingbird.waitForExistence(timeout: 5) && hummingbird.isHittable, "screen: \(app.debugDescription.prefix(3000))")
        hummingbird.tap()
        XCTAssertTrue(app.staticTexts["Anna's Hummingbird"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
        tapBack(app)

        let more = app.buttons["goal-patches-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(more.label, "\(12 - patches.count) more", "the row adds up to the count")
        more.tap()
        XCTAssertTrue(app.navigationBars["\(monthName()) goal"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
        let onTheBoard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'goal-patch-'"))
        XCTAssertEqual(onTheBoard.count, 12, "every one of them")
        app.buttons["goal-patch-Sayornis nigricans"].tap()
        XCTAssertTrue(app.staticTexts["Black Phoebe"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
    }

    private func monthName() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL"
        return formatter.string(from: .now)
    }

    @MainActor
    func testListenNamesTheGuildClosestToItsGoalAndOpensIt() {
        let app = launch(["-autoScreen", "listen", "-autoScrollTo", "local-set"])
        let line = app.buttons["listen-guild-goal"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(line.label, "Sunday Group is 2 birds from its \(monthName()) goal")
        XCTAssertTrue(app.scrolledTo(line))
        line.tap()
        XCTAssertTrue(element(app, "goal-monthly").waitForExistence(timeout: 8), "the Guild's page; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testListenHasNoLineWithoutAGoalRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "empty", "-autoScreen", "listen"]
        app.launch()
        XCTAssertTrue(app.buttons["Start listening"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["listen-guild-goal"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testASetsRowShowsFriendsOnBirdsYouHaventFound() {
        let app = launch(["-autoScreen", "set", "-autoScrollTo", "set-rows"])
        let duck = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jo Park and Sam Okafor have this bird'")).firstMatch
        XCTAssertTrue(duck.waitForExistence(timeout: 20), "faces land as the friends are read; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(duck.label.contains("Muscovy Duck"), duck.label)

        // Jo has the Canada Goose, and so do you: no face.
        let goose = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Canada Goose'")).firstMatch
        XCTAssertTrue(goose.exists)
        XCTAssertFalse(goose.label.contains("Jo Park"), goose.label)

        // The row still opens the bird, faces and all.
        XCTAssertTrue(app.scrolledTo(duck))
        duck.tap()
        XCTAssertTrue(app.staticTexts["Muscovy Duck"].waitForExistence(timeout: 8), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAPaperCardNamesTheFriendsWhoHaveTheBird() {
        let app = launch(["-autoScreen", "card-back", "-autoCardSpecies", "Sayornis nigricans"])
        let friends = element(app, "card-friends")
        XCTAssertTrue(friends.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(friends.label.contains("Maya Ortiz"), friends.label)
        XCTAssertTrue(friends.label.hasSuffix("this bird."), friends.label)
        XCTAssertTrue(friends.isHittable, "in view without scrolling the card")
    }

    @MainActor
    func testBlockingAFriendTakesTheirFaceOffTheSet() {
        let app = launch(["-autoScreen", "circle-info"])
        // Jo, who shows on the duck's row.
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        let list = app.collectionViews.firstMatch
        let members = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Members'")).firstMatch
        for _ in 0..<24 where !(members.exists && members.isHittable) { list.swipeUp() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Jo Park'")).firstMatch
        let jo = row.exists ? row : app.staticTexts["Jo Park"].firstMatch
        for _ in 0..<4 where !jo.isHittable { list.swipeUp() }
        XCTAssertTrue(jo.waitForExistence(timeout: 5), "no Jo; screen: \(app.debugDescription.prefix(3000))")
        jo.press(forDuration: 1.0)
        let block = app.buttons["Block Jo Park…"]
        XCTAssertTrue(block.waitForExistence(timeout: 5), "no Block; screen: \(app.debugDescription.prefix(3000))")
        block.tap()
        let confirm = (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.alerts.firstMatch).buttons["Block Jo Park"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        confirm.tap()
        app.navigationBars.buttons["Done"].firstMatch.tap()

        app.tabBars.buttons["Atlas"].tap()
        // From a set's plate.
        let plate = app.buttons["guide-set-us-ca-la"]
        XCTAssertTrue(plate.waitForExistence(timeout: 8) || app.scrolledTo(plate), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.scrolledTo(plate), "screen: \(app.debugDescription.prefix(3000))")
        plate.tap()
        let duck = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sam Okafor has this bird'")).firstMatch
        XCTAssertTrue(duck.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(duck.label.contains("Muscovy Duck"), duck.label)
        XCTAssertFalse(duck.label.contains("Jo Park"), duck.label)
    }
}
#endif
