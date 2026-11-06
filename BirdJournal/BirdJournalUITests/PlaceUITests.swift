import XCTest

/// The painting that follows you (issue #150), with real launches: `-autoLocation` is the phone's last known position, and a
/// pack index built from the repo's set definitions is what the phone has read, with none of the other sets' packs on it. The
/// painting's accessibility label and "Your local set" have to agree.
final class PlaceUITests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// An index of the five sets, as `packbuilder index` publishes them, without covers: the painting comes from the app.
    private static func indexFile() throws -> URL {
        var packs: [[String: Any]] = []
        for id in ["us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando"] {
            let data = try Data(contentsOf: repo.appending(path: "packbuilder/packs/\(id)/set.json"))
            let set = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            packs.append(["id": id, "name": set["name"] ?? id, "version": 1, "url": "https://example.com/\(id).zip", "sha256": "ab", "byteCount": 1, "set": set])
        }
        let url = URL.temporaryDirectory.appending(path: "place-index-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["packs": packs]).write(to: url)
        return url
    }

    @MainActor
    private func launch(_ arguments: [String]) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-inMemoryAlbum", "YES", "-packIndexURL", try Self.indexFile().absoluteString] + arguments
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
    func testThePaintingFollowsThePlaceIntoASetWhosePackIsntOnThePhone() throws {
        for (place, set) in [("joshua-tree", "California Deserts"), ("orlando", "Orlando & Space Coast"), ("san-diego", "San Diego"), ("oakland", "SF Bay Area"), ("griffith", "Los Angeles")] {
            let app = try launch(["-autoLocation", place])
            expectPainting(of: set, in: app)
            app.terminate()
        }
    }

    /// The set you're in beats your newest sighting's. Outside every set, or with location denied, it's your last set.
    @MainActor
    func testTheFallbackOrderWithSightings() throws {
        let inSanDiego = ["-seedNewestAt", "san-diego"]
        var app = try launch(inSanDiego + ["-autoLocation", "joshua-tree"])
        expectPainting(of: "California Deserts", in: app)
        app.terminate()
        app = try launch(inSanDiego + ["-autoLocation", "kansas"])
        expectPainting(of: "San Diego", in: app)
        app.terminate()
        app = try launch(inSanDiego + ["-autoLocation", "denied"])
        expectPainting(of: "San Diego", in: app)
        app.terminate()
        app = try launch(["-autoLocation", "denied", "-currentPlaceSetID", ""])
        expectPainting(of: "Los Angeles", in: app)
    }

    /// A launch with permission undecided asks nothing and falls back to the bundled set. Only Start may ask.
    @MainActor
    func testNoPermissionPromptAtLaunch() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["-inMemoryAlbum", "YES", "-packIndexURL", try Self.indexFile().absoluteString, "-currentPlaceSetID", ""]
        app.launch()
        expectPainting(of: "Los Angeles", in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Long enough for a prompt to have come up.
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 4), "a prompt at launch: \(springboard.alerts.firstMatch.debugDescription)")
        XCTAssertTrue(app.buttons["Start listening"].isHittable, "something is over the page")
    }

    /// The name, not just its words, opens the page, and the thread beside it takes no touch from the patches below.
    @MainActor
    func testTheLocalSetAndItsLatestPatchOpen() throws {
        let app = try launch(["-seedJournal", "YES", "-autoLocation", "griffith", "-collectionIntroShown", "YES"])
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
}
