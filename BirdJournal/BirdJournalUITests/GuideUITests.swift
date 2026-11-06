import XCTest

/// The profile's reference sounds (issue #41): a real tap plays the song, the row turns into its stop control, the
/// clip plays to its end, and a tap on the playing call stops it.
final class GuideUITests: XCTestCase {
    /// The Atlas (issue #118): a set's tile keeps the birder's "sewn" apart from "Ready offline", and the
    /// profile keeps its full credits a tap away.
    @MainActor
    func testTheAtlasKeepsSpeciesCollectedApartFromReadyOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "guide"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Atlas"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons["guide-set-us-ca-la"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(tile.label.contains("Los Angeles"), tile.label)
        XCTAssertTrue(tile.label.contains("Citrus edition"), tile.label)
        XCTAssertTrue(tile.label.contains("Ready offline"), tile.label)
        XCTAssertTrue(tile.label.contains("0 of 160 sewn"), "nothing collected yet, though the pack is on the phone: \(tile.label)")
        tile.tap()
        XCTAssertTrue(app.navigationBars["Los Angeles"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTheProfileHasItsStoryAndItsCreditsATapAway() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "profile"]
        app.launch()

        let credits = app.buttons["profile-credits"]
        XCTAssertTrue(app.staticTexts["About this bird"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.staticTexts["The tale"].exists, "the story's own title is its heading")
        for _ in 0..<12 where !(credits.exists && credits.isHittable) { app.swipeUp() }
        XCTAssertTrue(credits.isHittable, "screen: \(app.debugDescription.prefix(3000))")
        credits.tap()
        XCTAssertTrue(app.navigationBars["Sources & credits"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testSongAndCallPlayFromTheProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-autoScreen", "profile"]
        app.launch()

        let song = app.buttons["sound-song"]
        XCTAssertTrue(song.waitForExistence(timeout: 15), "no song row; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<3 where !song.isHittable { app.swipeUp() }
        XCTAssertEqual(song.label, "Play the song")
        XCTAssertTrue(song.value as? String ?? "" != "", "no credit beside the control")

        song.tap()
        XCTAssertTrue(song.waitForLabel("Stop the song", timeout: 5), "the song did not start; label \(song.label)")
        XCTAssertTrue(song.waitForLabel("Play the song", timeout: 15), "the 8 s clip did not end on its own")

        let call = app.buttons["sound-call"]
        XCTAssertTrue(call.exists)
        call.tap()
        XCTAssertTrue(call.waitForLabel("Stop the call", timeout: 5), "the call did not start; label \(call.label)")
        call.tap()
        XCTAssertTrue(call.waitForLabel("Play the call", timeout: 5), "a tap on the playing call did not stop it")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Issue #134: the Atlas's search is always in view, not behind a pull down the page.
    @MainActor
    func testTheAtlasSearchIsInViewAndFindsABird() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoScreen", "guide"]
        app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "no search field in view; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("Black Phoebe")
        XCTAssertTrue(app.staticTexts["Sayornis nigricans"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
    }

    /// Issue #150: a set's page makes its rows as they come on screen, not all 160 when it opens (XCUITest lists what's off
    /// screen too, so the count is what was made), and the last bird is still there at the end of a scroll.
    @MainActor
    func testASetsPageMakesItsRowsAsTheyScrollIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoScreen", "set"]
        app.launch()
        let rows = app.buttons.matching(identifier: "set-species-silhouette")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertLessThan(rows.count, 40, "made at open")
        let last = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '160, '")).firstMatch
        for _ in 0..<40 where !last.exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.exists, "screen: \(app.debugDescription.prefix(3000))")
    }

    /// Issue #134: a set's page searches its own birds, by name, keeping their collector numbers.
    @MainActor
    func testASetsPageSearchesItsBirds() {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-autoScreen", "set"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(identifier: "set-species-silhouette").firstMatch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        // As the reference draws it, the page opens on its plate: the search is a pull away.
        let search = app.searchFields.firstMatch
        for _ in 0..<3 where !search.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no search field in view; screen: \(app.debugDescription.prefix(3000))")
        search.tap()
        search.typeText("House Finch")
        let finch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '130, House Finch'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons.matching(identifier: "set-species-silhouette").count, 1, "only the match; screen: \(app.debugDescription.prefix(3000))")
        search.typeText("zzz")
        XCTAssertTrue(app.descendants(matching: .any)["no-search-match"].waitForExistence(timeout: 5))
    }
}

extension XCUIElement {
    /// Waits for the element's accessibility label to read `label`.
    func waitForLabel(_ label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
