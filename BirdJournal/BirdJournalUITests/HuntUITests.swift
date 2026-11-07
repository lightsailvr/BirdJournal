import XCTest

/// Issue #150 (L1, L2, V2, A2): real taps on a phone run over the soundscape, in Griffith Park so an add sews a Los Angeles
/// patch with a painting. Sew it and Add go straight to the add, with the reveal or the count and Undo; the rest of the row opens
/// the review. Skipped when the clip is not on disk (`scripts/download-clips.sh`).
final class HuntUITests: XCTestCase {
    private static func clip() throws -> String {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: clip) else { throw XCTSkip("no example soundscape at \(clip)") }
        return clip
    }

    /// A run that's heard these birds and holds still: an acorn woodpecker you haven't got here, the seeds' House Finch and Black
    /// Phoebe, and a Common Blackbird no pack describes.
    private static let birds = "Melanerpes formicivorus_Acorn Woodpecker,Haemorhous mexicanus_House Finch,Sayornis nigricans_Black Phoebe,Turdus merula_Common Blackbird"

    @MainActor
    private func launchRun(_ extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedJournal", "YES", "-fakeRunBirds", Self.birds,
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening", "-stitchInSeconds", "60",
        ] + extra
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, beginning prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testEachLookHasItsButtonAndTheSummaryLeadsWithWhatsWaiting() throws {
        let app = try launchRun()
        let sew = app.buttons["Sew it, Acorn Woodpecker"]
        XCTAssertTrue(sew.waitForExistence(timeout: 60), "no Sew it; screen: \(app.debugDescription.prefix(3000))")
        // The seeded blackbird is on no set's list, so here too it joins its Uncharted patch.
        XCTAssertTrue(app.staticTexts["1 new patch waiting and 3 you already have"].exists, "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["Possible matches. Add the birds you recognize."].exists)
        XCTAssertEqual(button(app, beginning: "Acorn Woodpecker, ").label, "Acorn Woodpecker, calling now, new patch waiting")
        XCTAssertTrue(app.buttons["Add House Finch"].exists)
        XCTAssertEqual(button(app, beginning: "House Finch, ").label, "House Finch, heard 3 min ago, you have this patch, seen 2 times")
        XCTAssertTrue(app.buttons["Add Black Phoebe"].exists)
        XCTAssertTrue(app.buttons["Review Common Blackbird"].exists, "a bird no pack describes keeps Review")
        XCTAssertFalse(app.buttons["Sew it, Common Blackbird"].exists)
        XCTAssertFalse(app.buttons["Review House Finch"].exists, "no Review on a bird a pack describes")
        XCTAssertFalse(app.buttons["Stop listening"].frame.width > 300, "Stop is quieter than the birds: not the screen's width")
    }

    @MainActor
    func testSewItStitchesRevealsAndUndoTakesItBack() throws {
        let app = try launchRun()
        let sew = app.buttons["Sew it, Acorn Woodpecker"]
        XCTAssertTrue(sew.waitForExistence(timeout: 60), "no Sew it; screen: \(app.debugDescription.prefix(3000))")
        sew.tap()

        let stitching = app.buttons["stitch-in"]
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "no stitch-in; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(stitching.label, "Sewing your Acorn Woodpecker patch")
        stitching.tap()
        let reveal = app.staticTexts["New patch, Citrus edition"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "no reveal; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["Your first Acorn Woodpecker in Los Angeles"].exists, "screen: \(app.debugDescription.prefix(4000))")

        let undo = app.buttons["Undo adding Acorn Woodpecker"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no Undo; screen: \(app.debugDescription.prefix(4000))")
        undo.tap()
        XCTAssertFalse(reveal.waitForExistence(timeout: 2), "Undo closes the reveal")
        XCTAssertTrue(sew.waitForExistence(timeout: 10), "the bird is new again; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertTrue(app.staticTexts["1 new patch waiting and 3 you already have"].exists, "screen: \(app.debugDescription.prefix(3000))")

        // Sewn and kept, the row shows it: the patch and a check, and none waiting.
        sew.tap()
        XCTAssertTrue(stitching.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        stitching.tap()
        let keepListening = app.buttons["Keep listening"]
        XCTAssertTrue(keepListening.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")
        keepListening.tap()
        XCTAssertTrue(app.buttons["Added. Review Acorn Woodpecker"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertEqual(button(app, beginning: "Acorn Woodpecker, ").label, "Acorn Woodpecker, calling now, added, you have this patch, seen once")
        XCTAssertTrue(app.staticTexts["4 birds you already have"].exists, "screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAddTicksTheCountAndUndoTakesItBack() throws {
        let app = try launchRun()
        let add = app.buttons["Add House Finch"]
        XCTAssertTrue(add.waitForExistence(timeout: 60), "no Add on the seeded bird; screen: \(app.debugDescription.prefix(3000))")
        add.tap()

        let seenAgain = app.staticTexts["House Finch seen again, 3 times in Los Angeles"]
        XCTAssertTrue(seenAgain.waitForExistence(timeout: 10), "no count; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "a repeat stitches nothing")
        XCTAssertFalse(app.buttons["Keep listening"].exists, "and opens no page")
        XCTAssertTrue(app.buttons["Added. Review House Finch"].waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(4000))")

        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5), "it can be added again; screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(seenAgain.exists, "the count went with it")
        XCTAssertEqual(button(app, beginning: "House Finch, ").label, "House Finch, heard 3 min ago, you have this patch, seen 2 times")
    }

    @MainActor
    func testARowItselfOpensTheReviewAndAddsNothingWithThePhotoFirst() throws {
        let app = try launchRun()
        let row = button(app, beginning: "House Finch, ")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "no review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.segmentedControls["review-method"].waitForExistence(timeout: 5), "Heard or Seen is on the review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "nothing added")
        XCTAssertFalse(app.buttons["profile-patch"].exists, "in a review the photo comes first; screen: \(app.debugDescription.prefix(3000))")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Add House Finch"].waitForExistence(timeout: 10), "still not added; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testABirdNoPackDescribesOpensItsReview() throws {
        let app = try launchRun()
        let review = app.buttons["Review Common Blackbird"]
        XCTAssertTrue(review.waitForExistence(timeout: 60), "no Review; screen: \(app.debugDescription.prefix(3000))")
        review.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "no review; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["stitch-in"].exists, "nothing added")
    }

    /// The bird a row shows. Its label's other words can change while the list holds: a row's own contents aren't held.
    private func bird(_ row: XCUIElement) -> String {
        String(row.label.prefix { $0 != "," })
    }

    /// A woodpecker always calling, and five with patches that keep passing their places along once a second, each with Add.
    /// (A launch argument can't hold an apostrophe: the defaults read it as a property list and drop every flag.)
    private static let movingBirds = "Melanerpes formicivorus_Acorn Woodpecker,Buteo jamaicensis_Red-tailed Hawk,Anas platyrhynchos_Mallard,Haemorhous mexicanus_House Finch,Sayornis nigricans_Black Phoebe,Zenaida macroura_Mourning Dove"

    /// The list holds still around a touch (the maintainer, issue #150). A finger comes down on one spot on a list that keeps
    /// re-sorting, and stays for 2.5 s, two or three re-sorts where it takes five to come round again. Whichever bird's Add was at
    /// that spot takes the add, and when the finger lifts that bird is still at that spot.
    @MainActor
    func testAFingerDownOnAListThatKeepsReSortingKeepsItsBirdUnderItAndTheListMovesAgainAfter() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-fakeRunReorderEvery", "1", "-fakeRunBirds", Self.movingBirds,
            // A row takes this test a few seconds to read, and the hold has to outlast that once the finger's up.
            "-listHoldSettle", "8",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")

        // It does keep moving when nobody's touching it.
        let first = bird(row)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != first }, evaluatedWith: NSObject())], timeout: 15)

        // The row's own button is the row's width less the pill, which sits to its right.
        let frame = row.frame
        let spot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX + 30, dy: frame.midY))
        let touched = Date.now
        spot.press(forDuration: 2.5)
        let said = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' seen again, 2 times in Los Angeles'")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 1), "the press added nothing; screen: \(app.debugDescription.prefix(4000))")
        let added = said.label.components(separatedBy: " seen again").first ?? ""
        XCTAssertTrue(row.label.hasPrefix("\(added), added"), "\(added) moved from under the finger: the row there is \(row.label)")

        // And it's let go: within a few seconds of the finger lifting, the list is moving again. This ends before the 20 s after the
        // touch when a finger that never said it lifted would be let go anyway (`HeldListOrder.staleAfter`), so only the lift can pass it.
        let left = max(touched.addingTimeInterval(19).timeIntervalSinceNow, 1)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != added }, evaluatedWith: NSObject())], timeout: left)
    }

    /// Scrolling counts as touching, with the finger nowhere near a row: here it's on the timer. These birds move three times a
    /// second, so two looks at one spot, a moment apart, would see different birds if the list weren't holding.
    @MainActor
    func testScrollingHoldsTheListAndItMovesAgainAfter() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-fakeRunReorderEvery", "0.3",
            "-fakeRunBirds", Self.movingBirds + ",Melozone crissalis_California Towhee,Spinus psaltria_Lesser Goldfinch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")
        let first = bird(row)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != first }, evaluatedWith: NSObject())], timeout: 15)

        let timer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Listening for'")).firstMatch
        XCTAssertTrue(timer.exists, "screen: \(app.debugDescription.prefix(3000))")
        let from = timer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -60)), withVelocity: .slow, thenHoldForDuration: 2)
        let held = bird(row)
        let words = row.label
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(bird(row), held, "the list moved during its 1.5 s after a scroll")
        XCTAssertNotEqual(row.label, words, "a row's own contents aren't held, only the order")

        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != held }, evaluatedWith: NSObject())], timeout: 15)
    }

    /// A flick still decelerating when the list leaves the screen never tells it the scroll is over, so leaving lets go.
    @MainActor
    func testAFlickThenAnotherTabDoesNotLeaveTheListHeld() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-fakeRunReorderEvery", "1", "-fakeLeaveDuringFlick", "YES",
            "-fakeRunBirds", Self.movingBirds + ",Melozone crissalis_California Towhee,Spinus psaltria_Lesser Goldfinch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")

        row.swipeUp(velocity: .fast)
        let collection = app.tabBars.buttons["Collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5) && collection.isSelected, "the flick didn't leave; screen: \(app.debugDescription.prefix(3000))")
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        // Well inside the safety net's time: this is leaving letting go, not the net.
        let held = bird(row)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != held }, evaluatedWith: NSObject())], timeout: 8)
    }

    /// Tapping the tab you're on scrolls to the top, which with the list already there never reports that it's over: only a
    /// finger or a deceleration holds the list, not that.
    @MainActor
    func testRetappingTheListenTabDoesNotHoldTheList() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-fakeRunReorderEvery", "1",
            "-fakeRunBirds", Self.movingBirds,
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")

        app.tabBars.buttons["Listen"].tap()
        let held = bird(row)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != held }, evaluatedWith: NSObject())], timeout: 8)
    }

    /// A sheet landing under a finger takes the touch away, so the list can't wait to hear it end.
    @MainActor
    func testASheetLandingMidTouchLetsTheListGo() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedBoard", "YES", "-fakeRunReorderEvery", "1", "-fakeSheetDuringTouch", "YES",
            "-fakeRunBirds", Self.movingBirds,
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")

        row.press(forDuration: 2.5)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no sheet; screen: \(app.debugDescription.prefix(3000))")
        close.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        let held = bird(row)
        wait(for: [expectation(for: NSPredicate { _, _ in self.bird(row) != held }, evaluatedWith: NSObject())], timeout: 8)
    }

    /// The finger's watcher leaves the touch to the scroll view.
    @MainActor
    func testTheListStillScrolls() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedJournal", "YES",
            "-fakeRunBirds", Self.movingBirds + ",Melozone crissalis_California Towhee,Spinus psaltria_Lesser Goldfinch",
            "-autoPhoneListening", try Self.clip(), "-autoLocation", "griffith", "-autoScreen", "listening",
        ]
        app.launch()
        let row = app.buttons["candidate-row-2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no row; screen: \(app.debugDescription.prefix(3000))")
        let before = row.frame.minY
        row.swipeUp()
        let scrolled = NSPredicate { _, _ in row.frame.minY < before }
        wait(for: [expectation(for: scrolled, evaluatedWith: NSObject())], timeout: 10)
    }

    // The maintainer, issue #150: "patches should only be on the patches". A row's picture is hidden from the tree, so these go by
    // what each row says of it and where it opens; `RowPictureSource` has no patch to show.

    @MainActor
    private func launchSeeded(_ screen: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-seedJournal", "YES", "-autoScreen", screen] + extra
        app.launch()
        return app
    }

    @MainActor
    func testASightingWithYourPhotoSaysSoAndOneWithoutSaysItsAReferencePhotoAndOpens() throws {
        let app = launchSeeded("sightings")
        let finch = button(app, beginning: "House Finch")
        XCTAssertTrue(finch.waitForExistence(timeout: 15), "no sighting row; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(finch.label.contains("Your glasses snapshot"), finch.label)
        XCTAssertFalse(finch.label.contains("Reference photo"), finch.label)
        let dove = button(app, beginning: "Mourning Dove")
        XCTAssertTrue(dove.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(dove.label.contains("Reference photo"), "a reference photo never reads as yours: \(dove.label)")
        XCTAssertFalse(dove.label.contains("Your"), dove.label)
        // The picture takes no touches of its own: a tap on it opens the sighting.
        dove.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        // A sighting's own page keeps its patch: that's the mark of the bird you found.
        XCTAssertTrue(app.descendants(matching: .any)["sighting-patch"].waitForExistence(timeout: 10), "the sighting opened; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testASpeciesRowOpensTheBirdsPatches() throws {
        let app = launchSeeded("species-list")
        let row = button(app, beginning: "Mourning Dove")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no species row; screen: \(app.debugDescription.prefix(3000))")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["board-patch"].waitForExistence(timeout: 10), "its patches are one tap on; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testAnAtlasSearchForAFoundBirdOpensItsProfileWithItsPhotoAndAWordLinkToThePatch() throws {
        let app = launchSeeded("guide", ["-autoQuery", "Finch"])
        let row = button(app, beginning: "House Finch")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no result; screen: \(app.debugDescription.prefix(3000))")
        row.tap()
        let patch = app.buttons["profile-patch"]
        XCTAssertTrue(patch.waitForExistence(timeout: 10), "no link; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(patch.label, "Your patch, Los Angeles")
        patch.tap()
        XCTAssertTrue(app.buttons["card-flip"].waitForExistence(timeout: 10), "the patch's page; screen: \(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testTheProfileLeadsWithItsPhotoThenItsStoryFoundOrNotAndAnUnfoundBirdHasNoLink() throws {
        let app = launchSeeded("profile", ["-autoCardSpecies", "Branta canadensis"])
        let credit = app.staticTexts["Reference photo"].firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 15), "no photo; screen: \(app.debugDescription.prefix(3000))")
        let about = app.staticTexts["About this bird"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertLessThan(credit.frame.minY, about.frame.minY)
        let photo = { (app: XCUIApplication) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Reference photo:'")).firstMatch }
        XCTAssertTrue(photo(app).exists, "screen: \(app.debugDescription.prefix(3000))")
        let unfoundPhotoY = photo(app).frame.minY
        XCTAssertFalse(app.buttons["profile-patch"].exists, "a bird you haven't found has no patch to go to")

        let found = launchSeeded("profile")
        XCTAssertTrue(found.buttons["profile-patch"].waitForExistence(timeout: 15), "screen: \(found.debugDescription.prefix(3000))")
        XCTAssertTrue(found.staticTexts["Reference photo"].firstMatch.exists, "it's the same page")
        XCTAssertGreaterThan(found.buttons["profile-patch"].frame.minY, found.staticTexts["Reference photo"].firstMatch.frame.maxY, "words, under the photo's credit")
        XCTAssertEqual(photo(found).frame.minY, unfoundPhotoY, accuracy: 1, "the photo's top sits in the same place, found or not")
    }
}
