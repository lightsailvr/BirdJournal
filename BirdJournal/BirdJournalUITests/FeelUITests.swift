import XCTest

/// Issue #150, slice 3: how the app answers, through real taps. What a birder feels (the zoom, the spring, the haptics themselves)
/// is for a phone; these prove the way to each one works and lands in the right place.
final class FeelUITests: XCTestCase {
    private static let clip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "fixtures/clips/birdnet-example-soundscape.wav")
        .path(percentEncoded: false)

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES"] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func board(_ extra: [String] = []) -> XCUIApplication {
        launch(["-seedJournal", "YES", "-autoScreen", "cards"] + extra)
    }

    /// The tile whose label starts with `name`.
    private func tile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'board-patch' AND label BEGINSWITH %@", name)).firstMatch
    }

    /// Where `element` rests once it has stopped moving.
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = element.frame
            if abs(now.minY - last.minY) < 0.5, abs(now.width - last.width) < 0.5 { return now }
            last = now
        }
        return last
    }

    @MainActor
    private func hapticLog(_ app: XCUIApplication) -> [String] {
        element(app, "haptic-log").label.split(separator: " ").map(String.init)
    }

    @MainActor
    private func waitForHaptic(_ haptic: String, count: Int = 1, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(15)
        while Date.now < deadline {
            if hapticLog(app).filter({ $0 == haptic }).count >= count { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("no \(count) × \(haptic): \(hapticLog(app))", file: file, line: line)
    }

    // MARK: - Lift

    @MainActor
    func testAPatchPageGoesBackToTheTileItWasOpenedFromEvenAfterASwipe() {
        let app = board()
        let phoebe = tile(app, "Black Phoebe")
        XCTAssertTrue(phoebe.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        let dove = tile(app, "Mourning Dove")
        let finch = tile(app, "House Finch")
        let frames = [settledFrame(of: phoebe), settledFrame(of: dove), settledFrame(of: finch)]
        phoebe.tap()

        let face = element(app, "patch-face")
        XCTAssertTrue(face.waitForExistence(timeout: 10), "the patch did not open: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(face.label.hasPrefix("Black Phoebe"), face.label)
        let swiped = app.buttons.matching(NSPredicate(format: "identifier == 'patch-face' AND label BEGINSWITH 'House Finch'")).firstMatch
        face.swipeLeft()
        XCTAssertTrue(swiped.waitForExistence(timeout: 5), "the swipe did not reach another patch: \(app.debugDescription.prefix(3000))")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(phoebe.waitForExistence(timeout: 10), "not back on the board")
        XCTAssertEqual(app.tabBars.buttons["Collection"].isSelected, true)
        XCTAssertFalse(element(app, "patch-face").exists, "the page has gone")
        // The board hasn't moved, so the page landed where it left.
        XCTAssertEqual(settledFrame(of: phoebe).minY, frames[0].minY, accuracy: 2)
        XCTAssertEqual(settledFrame(of: dove).minY, frames[1].minY, accuracy: 2)
        XCTAssertEqual(settledFrame(of: finch).minY, frames[2].minY, accuracy: 2)
        // And it opens again: the transition left nothing behind that takes the touch.
        phoebe.tap()
        XCTAssertTrue(face.waitForExistence(timeout: 10))
    }

    @MainActor
    func testEveryPatchTileOpensItsPageOnEachSurface() {
        // The Listen tab's latest patches.
        let app = launch(["-seedJournal", "YES", "-autoScreen", "listen"])
        let latest = app.buttons["board-patch"].firstMatch
        var swipes = 0
        while !latest.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(latest.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        latest.tap()
        XCTAssertTrue(element(app, "patch-face").waitForExistence(timeout: 10), "from Listen: \(app.debugDescription.prefix(3000))")

        // A species' patches: the same bird's tile is on a page under this one, and this is the one that opens.
        let species = launch(["-seedGallery", "YES", "-autoScreen", "gallery"])
        let tile = species.buttons["board-patch"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "screen: \(species.debugDescription.prefix(3000))")
        tile.tap()
        XCTAssertTrue(element(species, "patch-face").waitForExistence(timeout: 10), "from a species: \(species.debugDescription.prefix(3000))")
    }

    @MainActor
    func testUnderReduceMotionAPatchStillOpensAndGoesBack() {
        let app = board(["-reduceMotion", "YES"])
        let phoebe = tile(app, "Black Phoebe")
        XCTAssertTrue(phoebe.waitForExistence(timeout: 15))
        phoebe.tap()
        XCTAssertTrue(element(app, "patch-face").waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(phoebe.waitForExistence(timeout: 10))
    }

    // MARK: - The peek

    @MainActor
    func testALongPressPeeksWithTurnOverShareAndAllSightings() {
        let app = board()
        let finch = tile(app, "House Finch")
        XCTAssertTrue(finch.waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")

        finch.press(forDuration: 1.2)
        let turn = app.buttons["Turn over"]
        XCTAssertTrue(turn.waitForExistence(timeout: 5), "no peek: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["All 2 sightings"].exists, "\(app.debugDescription.prefix(3000))")
        turn.tap()
        XCTAssertTrue(element(app, "card-name").waitForExistence(timeout: 10), "Turn over opens on the paper card: \(app.debugDescription.prefix(3000))")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(finch.waitForExistence(timeout: 10))
        finch.press(forDuration: 1.2)
        let all = app.buttons["All 2 sightings"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        XCTAssertTrue(app.buttons["patch-sighting"].firstMatch.waitForExistence(timeout: 10), "All sightings: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons.matching(identifier: "patch-sighting").count, 2)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(finch.waitForExistence(timeout: 10))
        finch.press(forDuration: 1.2)
        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(app.navigationBars["Share this patch"].waitForExistence(timeout: 10), "no share sheet: \(app.debugDescription.prefix(3000))")
    }

    // MARK: - The set's menu

    @MainActor
    func testTheSetsNameIsTheMenuForOtherSetsAndCarriesTheTotal() {
        let app = board()
        let name = app.buttons["collection-board"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "no set menu: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(name.label, "Los Angeles")
        XCTAssertFalse(app.navigationBars["Collection"].buttons["Set"].exists, "the toolbar's stack is gone")
        XCTAssertTrue(element(app, "cards-set-progress").label.contains("3 of 160 sewn"), element(app, "cards-set-progress").label)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5 patches'")).firstMatch.exists, "the total isn't on the page beside the count: \(app.debugDescription.prefix(3000))")

        name.tap()
        let uncharted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Uncharted'")).firstMatch
        XCTAssertTrue(uncharted.waitForExistence(timeout: 5), "no list of sets: \(app.debugDescription.prefix(3000))")
        let total = app.descendants(matching: .any).matching(NSPredicate(format: "label == '5 patches, 6 sightings'")).firstMatch
        XCTAssertTrue(total.exists, "the total is in the menu: \(app.staticTexts.allElementsBoundByIndex.map(\.label)), \(app.buttons.allElementsBoundByIndex.map(\.label))")
        uncharted.tap()

        XCTAssertTrue(tile(app, "Common Blackbird").waitForExistence(timeout: 5), "the Uncharted board: \(app.debugDescription.prefix(3000))")
        XCTAssertEqual(app.buttons["collection-board"].label, "Uncharted")
        XCTAssertTrue(app.staticTexts["2 outside every set"].exists, "\(app.debugDescription.prefix(3000))")
    }

    @MainActor
    func testWithOneSetItsNameIsJustItsName() {
        let app = launch(["-seedBoard", "YES", "-autoScreen", "cards"])
        XCTAssertTrue(element(app, "cards-set-progress").waitForExistence(timeout: 15), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["collection-board"].exists, "nothing to choose")
        XCTAssertTrue(app.staticTexts["Los Angeles"].exists)
    }

    // MARK: - Modes

    /// The middle of the window's foot, averaged: only the surface shows there on these short boards.
    private func surfaceColour(of screenshot: XCUIScreenshot) -> (red: Double, green: Double, blue: Double) {
        let image = screenshot.image
        let scale = image.scale
        let box = CGRect(x: 20 * scale, y: (image.size.height - 180) * scale, width: 40 * scale, height: 40 * scale)
        guard let crop = image.cgImage?.cropping(to: box) else { return (0, 0, 0) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .medium
        context?.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    @MainActor
    func testChangingModeCrossFadesTheSurfaceToTheRightMode() throws {
        // Slowed, so the fade can be caught under way; a hard cut would show one colour or the other.
        let app = board(["-modeFadeSeconds", "6"])
        let modes = app.segmentedControls["collection-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 15))
        XCTAssertTrue(tile(app, "House Finch").waitForExistence(timeout: 10))
        let felt = surfaceColour(of: app.screenshot())

        modes.buttons["Sightings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let during = surfaceColour(of: app.screenshot())
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '6 sightings'")).firstMatch.waitForExistence(timeout: 10), "\(app.debugDescription.prefix(3000))")
        Thread.sleep(forTimeInterval: 7)
        let page = surfaceColour(of: app.screenshot())

        let span = abs(felt.red - page.red) + abs(felt.green - page.green) + abs(felt.blue - page.blue)
        XCTAssertGreaterThan(span, 30, "felt and the page differ: \(felt) \(page)")
        let fromFelt = abs(during.red - felt.red) + abs(during.green - felt.green) + abs(during.blue - felt.blue)
        let fromPage = abs(during.red - page.red) + abs(during.green - page.green) + abs(during.blue - page.blue)
        XCTAssertGreaterThan(fromFelt, span * 0.1, "under way it has left the felt: \(felt) \(during) \(page)")
        XCTAssertGreaterThan(fromPage, span * 0.1, "and hasn't reached the page: \(felt) \(during) \(page)")

        XCTAssertFalse(tile(app, "House Finch").exists, "the board has gone")
        XCTAssertTrue(modes.buttons["Sightings"].isSelected)
    }

    // MARK: - Splash

    @MainActor
    func testTheSplashPlaysOnTheFirstLaunchOnly() {
        let first = XCUIApplication()
        first.launchArguments = ["-inMemoryAlbum", "YES", "-resetLaunchSplash", "YES", "-launchSplashSeconds", "8"]
        first.launch()
        XCTAssertTrue(element(first, "launch-splash").waitForExistence(timeout: 5), "no splash on a first launch: \(first.debugDescription.prefix(3000))")
        first.terminate()

        let next = XCUIApplication()
        next.launchArguments = ["-inMemoryAlbum", "YES", "-launchSplashSeconds", "8"]
        next.launch()
        XCTAssertTrue(next.buttons["Start listening"].waitForExistence(timeout: 15), "screen: \(next.debugDescription.prefix(3000))")
        XCTAssertFalse(element(next, "launch-splash").exists, "a later launch goes straight to Listen")
        XCTAssertTrue(next.buttons["Start listening"].isHittable)
    }

    // MARK: - The reveal

    @MainActor
    func testTheNewPatchIsTheWayToTheCollectionAndThePageSaysLess() {
        let app = launch(["-seedJournal", "YES", "-autoScreen", "reveal", "-autoCardSpecies", "Sayornis nigricans", "-reduceMotion", "YES"])
        let patch = app.buttons["revealed-patch"]
        XCTAssertTrue(patch.waitForExistence(timeout: 15), "the patch is a button: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(patch.label.hasPrefix("Black Phoebe, Citrus edition patch"), patch.label)
        XCTAssertTrue(app.buttons["Done"].exists, "the one primary action")
        XCTAssertTrue(app.buttons["Share this patch"].exists)
        XCTAssertFalse(app.buttons["See it in my collection"].exists, "the patch does that")
        XCTAssertFalse(app.staticTexts["Your sighting is already saved."].exists)
        XCTAssertFalse(element(app, "revealed-shared").exists, "signed out, it isn't shared with anyone")

        patch.tap()
        XCTAssertFalse(patch.waitForExistence(timeout: 2), "the page closed")
        XCTAssertTrue(app.tabBars.buttons["Collection"].isSelected, "\(app.debugDescription.prefix(3000))")
        XCTAssertTrue(tile(app, "Black Phoebe").waitForExistence(timeout: 10), "on the board with the new patch: \(app.debugDescription.prefix(3000))")
    }

    #if ACCOUNTS_ENABLED
    @MainActor
    func testTheRevealSaysWhichGuildsItWasSharedWithOnlyIfItWas() {
        let arguments = ["-seedJournal", "YES", "-autoScreen", "reveal", "-autoCardSpecies", "Sayornis nigricans", "-reduceMotion", "YES", "-fakeAccount", "signedIn"]
        let shared = launch(arguments + ["-fakeCircles", "some"])
        let line = element(shared, "revealed-shared")
        XCTAssertTrue(line.waitForExistence(timeout: 15), "screen: \(shared.debugDescription.prefix(3000))")
        XCTAssertEqual(line.label, "Shared with Sunday Group and Family")

        let solo = launch(arguments + ["-fakeCircles", "empty"])
        XCTAssertTrue(solo.buttons["revealed-patch"].waitForExistence(timeout: 15))
        XCTAssertFalse(element(solo, "revealed-shared").waitForExistence(timeout: 3), "in no Guild")

        let quiet = launch(arguments + ["-fakeCircles", "some", "-shareFindsAutomatically", "<false/>"])
        XCTAssertTrue(quiet.buttons["revealed-patch"].waitForExistence(timeout: 15))
        XCTAssertFalse(element(quiet, "revealed-shared").waitForExistence(timeout: 3), "sharing is off")
    }
    #endif

    @MainActor
    func testWithMorePatchesWaitingThePatchIsOnlyAPatch() throws {
        // SewingUITests has a real glasses run reach this page; here, only what it offers.
        guard FileManager.default.fileExists(atPath: Self.clip) else { throw XCTSkip("no example soundscape") }
        let album = "feel-\(UUID().uuidString)"
        let app = XCUIApplication()
        app.launchArguments = [
            "-albumFile", album, "-collectionIntroShown", "YES", "-mockPreviewPort", "\(Int.random(in: 20_000...60_000))", "-reduceMotion", "YES",
            "-autoGlassesListening", Self.clip, "-autoLocation", "griffith", "-autoScreen", "glasses-run", "-autoLensAdd", "House Finch,Dark-eyed Junco",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Added. Review Dark-eyed Junco"].waitForExistence(timeout: 120), "\(app.debugDescription.prefix(3000))")
        app.buttons["Stop listening"].tap()
        XCTAssertTrue(app.buttons["Next patch"].waitForExistence(timeout: 15), "\(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons["revealed-patch"].exists, "going to the collection waits for the last")
        XCTAssertTrue(element(app, "revealed-patch").exists)
        app.buttons["Next patch"].tap()
        XCTAssertTrue(app.buttons["revealed-patch"].waitForExistence(timeout: 5), "the last one: \(app.debugDescription.prefix(3000))")
    }

    // MARK: - Haptics

    @MainActor
    func testTheRightMomentsAskForTheRightHaptics() {
        let app = board(["-hapticLog", "YES"])
        let phoebe = tile(app, "Black Phoebe")
        XCTAssertTrue(phoebe.waitForExistence(timeout: 15))
        XCTAssertEqual(hapticLog(app), [], "nothing on opening a tab")
        phoebe.tap()
        waitForHaptic("lift", app)
        let flip = element(app, "card-flip")
        XCTAssertTrue(flip.waitForExistence(timeout: 10))
        flip.tap()
        waitForHaptic("turn", app)
        flip.tap()
        waitForHaptic("turn", count: 2, app)
        XCTAssertEqual(hapticLog(app).filter { $0 == "lift" }.count, 1, "\(hapticLog(app))")
    }

    @MainActor
    func testARunStartsAndStopsWithItsHaptic() throws {
        guard FileManager.default.fileExists(atPath: Self.clip) else { throw XCTSkip("no example soundscape") }
        let app = launch(["-hapticLog", "YES", "-autoPhoneListening", Self.clip, "-autoLocation", "denied", "-autoScreen", "listen"])
        let start = app.buttons["Start listening"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "\(app.debugDescription.prefix(3000))")
        start.tap()
        waitForHaptic("startStop", app)
        let stop = app.buttons["Stop listening"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let listening = NSPredicate(format: "isEnabled == YES")
        wait(for: [expectation(for: listening, evaluatedWith: stop)], timeout: 60)
        stop.tap()
        waitForHaptic("startStop", count: 2, app)
    }

    @MainActor
    func testASewnPatchTicksThenSucceeds() throws {
        guard FileManager.default.fileExists(atPath: Self.clip) else { throw XCTSkip("no example soundscape") }
        let app = launch(["-hapticLog", "YES", "-autoPhoneListening", Self.clip, "-autoLocation", "griffith", "-autoScreen", "listening"])
        let review = app.buttons["Review House Finch"]
        let add = app.buttons["Add and sew patch"]
        for _ in 0..<5 {
            XCTAssertTrue(review.waitForExistence(timeout: 90), "\(app.debugDescription.prefix(3000))")
            review.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
            if app.staticTexts["House Finch"].exists, add.waitForExistence(timeout: 10) {
                add.tap()
                break
            }
            app.buttons["Close"].tap()
        }
        let keepListening = app.buttons["Keep listening"]
        XCTAssertTrue(keepListening.waitForExistence(timeout: 20), "\(app.debugDescription.prefix(3000))")
        keepListening.tap()
        waitForHaptic("stitchDone", app)
        let log = hapticLog(app)
        let ticks = log.indices.filter { log[$0] == "stitchTick" }
        XCTAssertGreaterThan(ticks.count, 2, "a tick a thread: \(log)")
        XCTAssertLessThan(ticks.last ?? 0, log.firstIndex(of: "stitchDone") ?? 0, "the ticks, then the last stitch: \(log)")
    }

    #if ACCOUNTS_ENABLED
    @MainActor
    func testAReactionAsksForItsHaptic() {
        let app = launch(["-hapticLog", "YES", "-fakeAccount", "signedIn", "-fakeCircles", "some", "-autoScreen", "circle"])
        let lovely = app.buttons["react-lovely-00000000-0000-4000-8000-000000000000"]
        app.scrolledTo(lovely, limit: 24)
        XCTAssertTrue(lovely.exists, "\(app.debugDescription.prefix(3000))")
        lovely.tap()
        waitForHaptic("reaction", app)
    }
    #endif
}
