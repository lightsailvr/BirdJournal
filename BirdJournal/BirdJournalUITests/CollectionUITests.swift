import XCTest

/// Issues #117 and #134: the board opens on the set you're in and shows only your patches; a patch's page hides
/// the tab bar; returning from a page keeps the current position, while switching modes starts at the top (#180).
/// Real taps on the seeded journal: three birds in Los Angeles, and two outside every set (`-seedBoard`: 30, enough to scroll).
final class CollectionUITests: XCTestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-seedJournal", "YES", "-collectionIntroShown", "YES", "-autoScreen", "cards"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testTheBoardShowsOnlyYourPatchesInCollectorOrder() throws {
        let app = launch()
        let sewn = app.buttons.matching(identifier: "board-patch")
        XCTAssertTrue(sewn.firstMatch.waitForExistence(timeout: 15), "no patches on the board; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(sewn.count, 3, "the three birds found in Los Angeles; screen: \(app.debugDescription.prefix(4000))")
        let names = sewn.allElementsBoundByIndex.map { $0.label.split(separator: ",").first.map(String.init) ?? "" }
        XCTAssertEqual(names, ["Mourning Dove", "Black Phoebe", "House Finch"], "collector order")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'not yet found'")).firstMatch.exists, "a bird you haven't found has no patch")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Canada Goose'")).firstMatch.exists)
    }

    @MainActor
    func testASearchReadsEveryBoardAndKeepsWhatMatches() throws {
        let app = launch(["-autoQuery", "House Finch"])
        let finch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, Citrus edition patch, seen 2 times'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mourning Dove'")).firstMatch.exists, "the search kept only the match")
    }

    /// Search sits in the title's row as a magnifier, opens to a field, and leaves the picker where it was.
    @MainActor
    func testTheMagnifierSearchesAndThePickerStaysWhereItWas() throws {
        try checkTheMagnifier(launch())
    }

    /// The same at the largest text, where the field as a drawer took 124 pt.
    @MainActor
    func testTheMagnifierAtTheLargestTextStaysInItsRow() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try checkTheMagnifier(app)
        XCTAssertLessThan(app.descendants(matching: .any)["collection-search"].firstMatch.frame.height, 70, "\(app.descendants(matching: .any)["collection-search"].firstMatch.frame)")
        if let folder = ProcessInfo.processInfo.environment["BIRDJOURNAL_FEEL_SHOTS"] {
            try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "search-ax5.png"))
        }
    }

    @MainActor
    private func checkTheMagnifier(_ app: XCUIApplication) throws {
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        let frame = modes.frame
        let before = pickerWords(in: app.screenshot(), at: frame)
        let search = app.buttons["collection-search-open"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "no magnifier: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.descendants(matching: .any)["collection-search"].firstMatch.exists, "no field until asked for")
        search.tap()
        let field = app.descendants(matching: .any)["collection-search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field: \(app.debugDescription.prefix(3000))")
        field.typeText("House")
        let finch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'House Finch, Citrus edition patch'")).firstMatch
        XCTAssertTrue(finch.waitForExistence(timeout: 10), "\(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mourning Dove'")).firstMatch.exists, "the search kept only the match")
        XCTAssertGreaterThan(correlation(before, pickerWords(in: app.screenshot(), at: frame)), 0.8, "the picker moved")
    }

    @MainActor
    func testASearchForABirdYouHaventFoundSaysSo() throws {
        let app = launch(["-autoQuery", "Canada Goose"])
        XCTAssertTrue(app.descendants(matching: .any)["no-search-match"].waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(4000))")
    }

    @MainActor
    func testAPatchPageHidesTheTabBarAndCollectionComesBackAsLeft() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES"])
        let collectionTab = app.tabBars.buttons["Collection"]
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 15), "no Collection tab; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(collectionTab.isSelected)
        XCTAssertTrue(app.navigationBars["Collection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 10), "no board; screen: \(app.debugDescription.prefix(3000))")

        // Down the board to a patch clear of the floating tab bar; its page has no tab bar, and back finds the board where
        // it was.
        for _ in 0..<2 { app.swipeUp() }
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let shown = try XCTUnwrap(tiles.first { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let scrolledTo = Self.settledMinY(of: tile)
        tile.tap()
        XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.tabBars.firstMatch.exists && collectionTab.isHittable, "the tab bar shows on a patch's page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 10))
        XCTAssertTrue(collectionTab.isHittable, "no tab bar after closing the patch")
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(Self.settledMinY(of: tile), scrolledTo, accuracy: 4, "the board did not keep its scroll position")

        // Another mode, another tab and back: the mode stays.
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "the mode picker is not pinned in reach; screen: \(app.debugDescription.prefix(3000))")
        selectMode("Sightings", in: modes)
        app.tabBars.buttons["Listen"].tap()
        XCTAssertTrue(app.buttons["Start listening"].waitForExistence(timeout: 10))
        collectionTab.tap()
        XCTAssertTrue(modes.waitForExistence(timeout: 10))
        XCTAssertTrue(modes.buttons["Sightings"].isSelected, "Collection did not come back on Sightings")

        // Switching back to Patches starts at its top, unlike returning from a patch's own page.
        selectMode("Patches", in: modes)
        let firstPatch = app.buttons.matching(identifier: "board-patch").firstMatch
        XCTAssertTrue(firstPatch.waitForExistence(timeout: 5))
        XCTAssertTrue(firstPatch.isHittable, "the first patch should be visible without scrolling")
        XCTAssertTrue(app.buttons["cards-set-progress"].isHittable, "the board starts with its set's progress")
    }

    /// The tab bar hides on a patch's page, which clamps the offset at the board's foot: it has to come back all the same.
    @MainActor
    func testTheFootOfABoardComesBackWhereItWas() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES"])
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 15), "no board; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<8 { app.swipeUp() }
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let shown = try XCTUnwrap(tiles.last { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let before = Self.settledMinY(of: tile)
        for _ in 0..<3 {
            tile.tap()
            XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10), "the patch did not open; screen: \(app.debugDescription.prefix(3000))")
            // Read as soon as it's back and again later: right the first time, with nothing put right afterwards.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 10))
            XCTAssertEqual(tile.frame.minY, before, accuracy: 2, "the page landed elsewhere")
            Thread.sleep(forTimeInterval: 3)
            XCTAssertEqual(Self.settledMinY(of: tile), before, accuracy: 2, "the board's foot moved")
        }
    }

    /// The room that holds the offset while a patch's page is up can't be flicked into on the way back: no empty felt, then a jolt.
    @MainActor
    func testAFlickRightAfterComingBackFindsTheFootWhereItWas() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES", "-coverRoomSeconds", "20"])
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<8 { app.swipeUp() }
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let shown = try XCTUnwrap(tiles.last { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let tile = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let before = Self.settledMinY(of: tile)
        tile.tap()
        XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        app.swipeUp()
        XCTAssertEqual(Self.settledMinY(of: tile), before, accuracy: 3, "the flick went on past the foot into empty felt")
    }

    /// The keyboard comes up once, on opening: not again over the results, coming back from a patch's page or another tab.
    @MainActor
    func testTheKeyboardStaysDownComingBackToASearch() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES"])
        let search = app.buttons["collection-search-open"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        search.tap()
        let field = app.descendants(matching: .any)["collection-search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "it comes up on opening")
        field.typeText("Mallard\n")
        let mallard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mallard, '")).firstMatch
        XCTAssertTrue(mallard.waitForExistence(timeout: 10))
        let lowered = expectation(for: NSPredicate(format: "exists == NO"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [lowered], timeout: 5)

        mallard.tap()
        XCTAssertTrue(app.buttons["card-flip"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(mallard.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "up again over the results, from a patch's page")
        XCTAssertTrue(field.exists, "the search is still on")

        app.tabBars.buttons["Atlas"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(mallard.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "up again over the results, from another tab")
        XCTAssertTrue(field.exists, "the search is still on")
    }

    /// The close button's a real target, with its mark inside it, at the largest text too.
    @MainActor
    func testTheCloseButtonIsAFullTargetAtTheLargestText() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let search = app.buttons["collection-search-open"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let close = app.buttons["collection-search-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(close.frame.width, 44, "\(close.frame)")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44, "\(close.frame)")
        if let folder = ProcessInfo.processInfo.environment["BIRDJOURNAL_FEEL_SHOTS"] {
            try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "search-close-ax5.png"))
        }
    }

    /// The close button ends a search from any state: with the keyboard up or down, typed in or not.
    @MainActor
    private func checkClosingASearch(_ extra: [String]) throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES"] + extra)
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 15), "no board; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<3 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.5)
        let tiles = app.buttons.matching(identifier: "board-patch")
        let count = { tiles.count }
        let shown = try XCTUnwrap(tiles.allElementsBoundByIndex.first { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let left = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        let modes = app.segmentedControls["collection-mode"]
        let leftAt = Self.settledMinY(of: left) - modes.frame.minY
        let search = app.buttons["collection-search-open"]
        let field = app.descendants(matching: .any)["collection-search"].firstMatch
        let mallard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mallard, '")).firstMatch

        func expectClosed(_ how: String, line: UInt = #line) {
            XCTAssertTrue(search.waitForExistence(timeout: 5), "\(how): the field's still open: \(app.debugDescription.prefix(2000))", line: line)
            XCTAssertFalse(field.exists, "\(how): the field's still open", line: line)
            XCTAssertFalse(app.keyboards.firstMatch.exists, "\(how): the keyboard's still up", line: line)
            XCTAssertTrue(left.waitForExistence(timeout: 5), "\(how): the board didn't come back: \(app.debugDescription.prefix(2000))", line: line)
            XCTAssertGreaterThan(count(), 3, "\(how): still filtered", line: line)
            XCTAssertEqual(Self.settledMinY(of: left) - modes.frame.minY, leftAt, accuracy: 30, "\(how): not where it was", line: line)
        }

        // Keyboard up, nothing typed.
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["collection-search-close"].tap()
        expectClosed("keyboard up, nothing typed")

        // Keyboard up, typed.
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Mallard")
        XCTAssertTrue(mallard.waitForExistence(timeout: 10))
        app.buttons["collection-search-close"].tap()
        expectClosed("keyboard up, typed")

        // Keyboard down, typed: the keyboard's Search key lowers it.
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Mallard\n")
        XCTAssertTrue(mallard.waitForExistence(timeout: 10))
        let lowered = NSPredicate(format: "exists == NO")
        wait(for: [expectation(for: lowered, evaluatedWith: app.keyboards.firstMatch)], timeout: 5)
        app.buttons["collection-search-close"].tap()
        expectClosed("keyboard down, typed")
    }

    @MainActor
    func testClosingASearchFromAnyStateEndsIt() throws {
        try checkClosingASearch([])
    }

    @MainActor
    func testClosingASearchFromAnyStateEndsItAtTheLargestText() throws {
        try checkClosingASearch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    /// The new patch's page opens the collection at the top of the board: from far down it, and with a search open there.
    @MainActor
    private func checkTheRevealsPatchLandsAtTheTop(searching: Bool) throws {
        let app = launch(["-seedBoard", "YES", "-reduceMotion", "YES", "-autoScreen", "reveal", "-autoRevealDelay", "25"])
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 15), "no board; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<4 { app.swipeUp() }
        if searching {
            app.buttons["collection-search-open"].tap()
            let field = app.descendants(matching: .any)["collection-search"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.typeText("Mallard")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mallard, '")).firstMatch.waitForExistence(timeout: 10))
        }
        let patch = app.buttons["revealed-patch"]
        XCTAssertTrue(patch.waitForExistence(timeout: 40), "no reveal: \(app.debugDescription.prefix(3000))")
        // Once it's finished arriving: a tap while it's being presented can do nothing.
        for _ in 0..<20 where !patch.isHittable { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(patch.isHittable)
        patch.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(patch.exists, "the page closed")
        XCTAssertFalse(app.descendants(matching: .any)["collection-search"].firstMatch.exists, "the search is over")
        let first = app.buttons.matching(NSPredicate(format: "identifier == 'board-patch' AND label BEGINSWITH 'Canada Goose'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "not at the top of the board: \(app.debugDescription.prefix(3000))")
        XCTAssertLessThan(Self.settledMinY(of: first), 500, "not at the top of the board")
        XCTAssertGreaterThan(first.frame.minY, 200)
    }

    @MainActor
    func testTheRevealsPatchLandsAtTheTopOfTheBoard() throws {
        try checkTheRevealsPatchLandsAtTheTop(searching: false)
    }

    @MainActor
    func testTheRevealsPatchLandsAtTheTopOfTheBoardWithASearchOpen() throws {
        try checkTheRevealsPatchLandsAtTheTop(searching: true)
    }

    /// A search from far down a board starts at the top of its results, not at the old offset, and clearing it goes back.
    @MainActor
    func testASearchFromAScrolledBoardStartsAtTheTopAndClearingGoesBack() throws {
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 15), "no board; screen: \(app.debugDescription.prefix(3000))")
        for _ in 0..<6 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1.5)
        let tiles = app.buttons.matching(identifier: "board-patch").allElementsBoundByIndex
        let shown = try XCTUnwrap(tiles.first { Self.isClearOfBars($0, in: app) }, "no patch in view; screen: \(app.debugDescription.prefix(3000))")
        let left = app.buttons.matching(NSPredicate(format: "label == %@", shown.label)).firstMatch
        // Against the picker: at this size the open field's row isn't the small title's height.
        let modes = app.segmentedControls["collection-mode"]
        let leftAt = Self.settledMinY(of: left) - modes.frame.minY

        let search = app.buttons["collection-search-open"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let field = app.descendants(matching: .any)["collection-search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Mallard")
        let mallard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Mallard, '")).firstMatch
        XCTAssertTrue(mallard.waitForExistence(timeout: 10), "\(app.debugDescription.prefix(3000))")
        XCTAssertGreaterThanOrEqual(Self.settledMinY(of: mallard), modes.frame.maxY - 1, "the first result's above the bar")

        // The field's own clear button.
        field.buttons.firstMatch.tap()
        XCTAssertTrue(left.waitForExistence(timeout: 10), "\(app.debugDescription.prefix(3000))")
        // Near enough, not exact: at this size a one-column board's rows are estimated until they're seen. Clearing lands about 21 to 33 pt
        // off here, and closing, from further down, up to 92.
        XCTAssertEqual(Self.settledMinY(of: left) - modes.frame.minY, leftAt, accuracy: 50, "clearing it went somewhere else")
    }

    /// Issue #180: a long Species list must not lend its offset or lazy range to Sightings (or any other pair).
    @MainActor
    func testEveryModeSwitchStartsAtTheTopInALongJournal() throws {
        try checkModeSwitchesStartAtTop(longJournal: true)
    }

    @MainActor
    func testEveryModeSwitchStartsAtTheTopInAShortJournal() throws {
        try checkModeSwitchesStartAtTop(longJournal: false)
    }

    @MainActor
    private func checkModeSwitchesStartAtTop(longJournal: Bool) throws {
        let app = launch(longJournal ? ["-seedJournal", "NO", "-seedBoard", "YES"] : [])
        let picker = app.segmentedControls["collection-mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        let modes = ["Species", "Sightings", "Patches"]
        func firstRow(_ mode: String) -> XCUIElement {
            switch mode {
            case "Patches": return app.buttons.matching(identifier: "board-patch").firstMatch
            case "Sightings": return app.buttons.matching(NSPredicate(format: "label CONTAINS 'added from'")).firstMatch
            default: return app.buttons.matching(NSPredicate(format: "label CONTAINS 'sighting' AND label CONTAINS 'last'")).firstMatch
            }
        }
        // Remember the actual first row and its top position, rather than whichever row a reused lazy stack mounts.
        var first: [String: (label: String, y: CGFloat)] = [:]
        for mode in modes {
            selectMode(mode, in: picker)
            let row = firstRow(mode)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no first row in \(mode): \(app.debugDescription.prefix(2000))")
            first[mode] = (row.label, Self.settledMinY(of: row))
        }
        for source in modes {
            for target in modes where source != target {
                selectMode(source, in: picker)
                for _ in 0..<(longJournal ? 4 : 1) { app.swipeUp() }
                selectMode(target, in: picker)
                let expected = try XCTUnwrap(first[target])
                let row = app.buttons.matching(NSPredicate(format: "label == %@", expected.label)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(source) → \(target) lost its first row")
                XCTAssertTrue(row.isHittable, "\(source) → \(target) must show the first row without a scroll")
                XCTAssertEqual(Self.settledMinY(of: row), expected.y, accuracy: 4, "\(source) → \(target) did not start at the top")
            }
        }
        // A quick run of changes cancels any pending search return and leaves the final mode at its top too.
        for mode in ["Patches", "Sightings", "Species", "Patches"] {
            picker.buttons[mode].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(picker.buttons["Patches"].wait(for: \.isSelected, toEqual: true, timeout: 5))
        let expected = try XCTUnwrap(first["Patches"])
        let row = app.buttons.matching(NSPredicate(format: "label == %@", expected.label)).firstMatch
        XCTAssertTrue(row.isHittable)
        XCTAssertEqual(Self.settledMinY(of: row), expected.y, accuracy: 4)
    }

    /// A pinned segment's automatic scroll-to-visible hit point may be stale after returning from a page.
    /// Tap its visible centre once, then wait for the selected-state snapshot; never retry the interaction.
    @MainActor
    private func selectMode(_ title: String, in picker: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let segment = picker.buttons[title]
        segment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(segment.wait(for: \.isSelected, toEqual: true, timeout: 5), "\(title) did not become selected", file: file, line: line)
    }

    /// A mode change never shows the old mode moving: when the scroll has to go elsewhere, it has already gone.
    @MainActor
    func testTheOldModeHasGoneBeforeTheScrollMoves() throws {
        // The surface's fade is slowed: the words and tiles don't wait for it.
        let app = launch(["-seedJournal", "NO", "-seedBoard", "YES", "-modeFadeSeconds", "6"])
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["board-patch"].firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        modes.buttons["Sightings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["board-patch"].firstMatch.exists, "the board is still there, a sixth of the way through the surface's fade")
    }

    /// The set's menu stays in reach down a board, and the bar it's in keeps touches off what scrolls under it.
    @MainActor
    func testTheSetMenuIsInReachFromAScrolledBoard() throws {
        let app = launch(["-seedBoard", "YES"])
        let name = app.buttons["collection-board"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "no set menu; screen: \(app.debugDescription.prefix(3000))")
        let top = name.frame.minY
        for _ in 0..<4 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(name.frame.minY, top, accuracy: 0.5, "it stays in the bar")

        // The bar's empty end, with tiles scrolled under it: a tap there opens nothing.
        let frame = name.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.maxX - 30, dy: frame.midY))
            .tap()
        XCTAssertFalse(app.buttons["card-flip"].waitForExistence(timeout: 2), "a tap on the bar reached a tile under it")

        name.tap()
        let uncharted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch
        XCTAssertTrue(uncharted.waitForExistence(timeout: 5), "no list of sets; screen: \(app.debugDescription.prefix(3000))")
        uncharted.tap()
        XCTAssertEqual(app.buttons["collection-board"].label, "Uncharted")
    }

    @MainActor
    func testAnotherBoardIsChosenAndKeptAcrossTheTabs() throws {
        let app = launch()
        let collectionTab = app.tabBars.buttons["Collection"]
        let boards = app.buttons["collection-board"]
        XCTAssertTrue(boards.waitForExistence(timeout: 15), "no board menu; screen: \(app.debugDescription.prefix(3000))")
        boards.tap()
        let uncharted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch
        XCTAssertTrue(uncharted.waitForExistence(timeout: 5), "no board list; screen: \(app.debugDescription.prefix(3000))")
        uncharted.tap()
        let blackbird = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Common Blackbird, Uncharted patch'")).firstMatch
        XCTAssertTrue(blackbird.waitForExistence(timeout: 5), "the Uncharted board did not show; screen: \(app.debugDescription.prefix(3000))")
        app.tabBars.buttons["Atlas"].tap()
        collectionTab.tap()
        XCTAssertTrue(blackbird.waitForExistence(timeout: 10), "Collection did not keep its board")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Where `element`'s top rests once the scroll view has stopped (a swipe to the foot of the grid bounces first).
    @MainActor
    private static func settledMinY(of element: XCUIElement) -> CGFloat {
        var last = element.frame.minY
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = element.frame.minY
            if abs(now - last) < 0.5 { return now }
            last = now
        }
        return last
    }

    /// Whether `element` is on screen below the navigation bar and above the floating tab bar.
    @MainActor
    private static func isClearOfBars(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return frame.minY > window.minY + 120 && frame.minY < window.maxY - 260 && element.isHittable
    }
}
