import XCTest

/// Issue #150 slice 3's evidence for what takes a finger to reach: the set's menu, the peek, a mode part way through its fade and the
/// reveal with Undo open. Runs only for `docs/screenshots/150/feel/capture.sh`, which says where the pictures go.
final class FeelCaptureUITests: XCTestCase {
    private var folder: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BIRDJOURNAL_FEEL_SHOTS"], !path.isEmpty else { throw XCTSkip("only for the capture script") }
        folder = URL(fileURLWithPath: path, isDirectory: true)
    }

    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication) throws {
        let folder = try XCTUnwrap(folder)
        try app.screenshot().pngRepresentation.write(to: folder.appending(path: "\(name).png"))
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    func testTheSetsMenuAndThePeek() throws {
        let app = launch(["-seedJournal", "YES", "-autoScreen", "cards"])
        let name = app.buttons["collection-board"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        name.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        try shot("menu", app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Los Angeles'")).firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)

        let finch = app.buttons.matching(NSPredicate(format: "identifier == 'board-patch' AND label BEGINSWITH 'House Finch'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 5))
        finch.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Turn over"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        try shot("peek", app)
    }

    /// The menu pinned with the modes, partway down a board.
    @MainActor
    func testAScrolledBoard() throws {
        let app = launch(["-seedBoard", "YES", "-seedJournal", "YES", "-autoScreen", "cards"])
        XCTAssertTrue(app.buttons["collection-board"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        try shot("board-scrolled", app)
        app.navigationBars["Collection"].buttons.matching(NSPredicate(format: "label CONTAINS[c] 'search'")).firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        try shot("search", app)
    }

    /// For a recording: from a scrolled board to Sightings and back.
    @MainActor
    func testRecordAModeChange() throws {
        let app = launch(["-seedBoard", "YES", "-autoScreen", "cards"])
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 3)
        modes.buttons["Sightings"].tap()
        Thread.sleep(forTimeInterval: 3)
        modes.buttons["Patches"].tap()
        Thread.sleep(forTimeInterval: 3)
    }

    /// For a recording: open and back at the foot of a board.
    @MainActor
    func testRecordTheFoot() throws {
        let app = launch(["-seedBoard", "YES", "-autoScreen", "cards"])
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<8 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 3)
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let tile = try XCTUnwrap(tiles.last { $0.isHittable && $0.frame.minY < app.windows.firstMatch.frame.maxY - 260 })
        tile.tap()
        XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 3)
    }

    /// For a recording: the tile on the map sheet's own stack.
    @MainActor
    func testRecordInASheet() throws {
        let app = launch(["-seedJournal", "YES", "-autoScreen", "map", "-autoCardSpecies", "Sayornis nigricans", "-autoMapSpeciesPatches", "YES"])
        let tile = app.buttons["board-patch"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        tile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["patch-face"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 3)
    }

    /// For the script's recording: a tap on a tile, a swipe on the page, and back.
    @MainActor
    func testTheLift() throws {
        let app = launch(["-seedJournal", "YES", "-autoScreen", "cards"])
        let phoebe = app.buttons.matching(NSPredicate(format: "identifier == 'board-patch' AND label BEGINSWITH 'Black Phoebe'")).firstMatch
        XCTAssertTrue(phoebe.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        phoebe.tap()
        let face = app.descendants(matching: .any)["patch-face"].firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        face.swipeLeft()
        Thread.sleep(forTimeInterval: 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 3)
    }

    @MainActor
    func testAModePartWayThroughItsFade() throws {
        let app = launch(["-seedJournal", "YES", "-autoScreen", "cards", "-modeFadeSeconds", "6"])
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        modes.buttons["Sightings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try shot("mode-fade", app)
    }

    @MainActor
    func testTheRevealWithUndoOpen() throws {
        let clip = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/clips/birdnet-example-soundscape.wav").path(percentEncoded: false)
        let app = launch(["-reduceMotion", "YES", "-autoPhoneListening", clip, "-autoLocation", "griffith", "-autoScreen", "listening"])
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, '")).firstMatch
        let add = app.buttons["Add and sew patch"]
        for _ in 0..<5 {
            XCTAssertTrue(review.waitForExistence(timeout: 90))
            review.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
            if app.staticTexts["House Finch"].exists, add.waitForExistence(timeout: 10) {
                add.tap()
                break
            }
            app.buttons["Close"].tap()
        }
        XCTAssertTrue(app.buttons["Undo adding House Finch"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        try shot("reveal-undo", app)
    }
}
