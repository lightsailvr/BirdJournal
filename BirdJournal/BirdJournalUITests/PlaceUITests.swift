import XCTest

/// The painting that follows you (issue #150), with real launches: `-autoLocation` is the phone's last known position, and the
/// phone is a fresh install with the index out of reach, so all it has of the other sets is what shipped with the app. The
/// painting's accessibility label and "Your local set" have to agree.
final class PlaceUITests: XCTestCase {
    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-freshPackStorage", "YES", "-packIndexURL", "http://127.0.0.1:9/index.json"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func expectPainting(of set: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let painting = app.otherElements["listen-painting"].firstMatch
        let shows = NSPredicate(format: "label == %@", "\(set) cover, AI illustration")
        let found = expectation(for: shows, evaluatedWith: painting)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 20), .completed, "the painting isn't \(set)'s; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
        XCTAssertTrue(app.buttons["Your local set, \(set)"].waitForExistence(timeout: 10), "\"Your local set\" names another; screen: \(app.debugDescription.prefix(3000))", file: file, line: line)
    }

    @MainActor
    func testAFreshInstallOfflineShowsThePaintingOfThePlaceItsIn() {
        for (place, set) in [("joshua-tree", "California Deserts"), ("orlando", "Orlando & Space Coast"), ("san-diego", "San Diego"), ("oakland", "SF Bay Area"), ("griffith", "Los Angeles")] {
            let app = launch(["-autoLocation", place])
            expectPainting(of: set, in: app)
            app.terminate()
        }
    }

    /// The set you're in beats your newest sighting's. Outside every set, or with location denied, it's your last set.
    @MainActor
    func testTheFallbackOrderWithSightings() {
        let inSanDiego = ["-seedNewestAt", "san-diego"]
        var app = launch(inSanDiego + ["-autoLocation", "joshua-tree"])
        expectPainting(of: "California Deserts", in: app)
        app.terminate()
        app = launch(inSanDiego + ["-autoLocation", "kansas"])
        expectPainting(of: "San Diego", in: app)
        app.terminate()
        app = launch(inSanDiego + ["-autoLocation", "denied"])
        expectPainting(of: "San Diego", in: app)
        app.terminate()
        app = launch(["-autoLocation", "denied", "-currentPlaceSetID", ""])
        expectPainting(of: "Los Angeles", in: app)
    }

    /// A launch with permission undecided asks nothing and falls back to the bundled set. Only Start may ask.
    @MainActor
    func testNoPermissionPromptAtLaunch() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-inMemoryAlbum", "YES", "-collectionIntroShown", "YES", "-freshPackStorage", "YES", "-packIndexURL", "http://127.0.0.1:9/index.json", "-currentPlaceSetID", ""]
        app.launch()
        expectPainting(of: "Los Angeles", in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Long enough for a prompt to have come up.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4), "a prompt at launch: \(springboard.alerts.firstMatch.debugDescription)")
        XCTAssertTrue(app.buttons["Start listening"].isHittable, "something is over the page")
    }

    /// The name, not just its words, opens the page, and the thread beside it takes no touch from the patches below.
    @MainActor
    func testTheLocalSetAndItsLatestPatchOpen() {
        let app = launch(["-seedJournal", "YES", "-autoLocation", "griffith"])
        expectPainting(of: "Los Angeles", in: app)
        let patch = app.buttons.matching(identifier: "board-patch").firstMatch
        if !patch.waitForExistence(timeout: 5) || !patch.isHittable { app.swipeUp() }
        XCTAssertTrue(patch.waitForExistence(timeout: 10), "no latest patch; screen: \(app.debugDescription.prefix(3000))")
        patch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Los Angeles,")).firstMatch.waitForExistence(timeout: 10), "the patch's page; screen: \(app.debugDescription.prefix(3000))")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let local = app.buttons["Your local set, Los Angeles"]
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        XCTAssertTrue(app.navigationBars["Los Angeles"].waitForExistence(timeout: 10), "the set's page; screen: \(app.debugDescription.prefix(3000))")
    }

    /// Offline, a set the phone knows only from what shipped has its tile and page, with no Download to offer, and sewing a patch in
    /// it would count.
    @MainActor
    func testASetKnownOnlyFromWhatShippedOpensInTheAtlas() {
        let app = launch(["-autoLocation", "joshua-tree", "-autoScreen", "guide"])
        let desert = app.buttons["guide-set-us-ca-desert"]
        // The tiles are lazy, and the tab bar floats over the page's foot.
        let inReach = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 160)
        for _ in 0..<8 {
            if desert.waitForExistence(timeout: 2), inReach.contains(CGPoint(x: desert.frame.midX, y: desert.frame.midY)) { break }
            app.swipeUp()
        }
        XCTAssertTrue(desert.exists, "no tile; screen: \(app.debugDescription.prefix(3000))")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch.exists, "nothing to download it from")
        desert.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(app.navigationBars["California Deserts"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
        XCTAssertTrue(app.staticTexts["155 still out there"].waitForExistence(timeout: 10), "screen: \(app.debugDescription.prefix(3000))")
    }
}
